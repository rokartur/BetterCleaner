import Foundation

/// Recall layer beyond the fixed Library catalog: asks Spotlight (`mdfind`) for
/// app-associated files anywhere on disk, surfacing leftovers in non-standard
/// places — `~/Applications (Vendor)`, `/Users/Shared/<App>`, stray files in the
/// home folder, VM/data bundles, etc. It also covers `~/Library` and `/Library`,
/// which the catalog walks only to a fixed depth; the overlap is free because
/// `seenPaths` drops the duplicates.
///
/// Deliberately conservative: results are **never auto-selected** (they can
/// include large user data such as virtual machines) and are filtered with a tight
/// association test (exact vendor token / bundle-id / reverse-DNS namespace, so
/// "ParallelSession.pm" or "ParallelSCSIReporter" never match).
enum SpotlightScanner {
    private static let mdfind = "/usr/bin/mdfind"
    static let category = "Found by Spotlight"

    /// Find app-associated paths across every Spotlight-indexed volume. The fixed
    /// Library catalog remains the fast path; `seenPaths` removes its duplicates.
    static func scan(
        app: InstalledApp,
        seenPaths: Set<String>,
        otherAppPaths: Set<String> = [],
        includeSystem: Bool = true,
        excluded: Set<String> = [],
        isCancelled: @escaping () -> Bool = { false }
    ) -> [FileItem] {
        guard let query = metadataQuery(for: app.descriptor), !isCancelled() else { return [] }

        // One OR query covers names, bundle-id filenames and bundle metadata on
        // every indexed volume. The previous term × scope fan-out repeated the
        // same Spotlight work in many child processes.
        let candidates = Set(mdfindPaths(query, isCancelled: isCancelled).map(\.path))
        guard !isCancelled() else { return [] }

        let descriptor = app.descriptor
        let appPath = app.url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let accepted = candidates.filter { path in
            let url = URL(fileURLWithPath: path)
            // Every rejection below is a string or a cached lookup, so they run
            // before the metadata read, which is an `mds` round-trip per path.
            if path == appPath || path.hasPrefix(appPath + "/") { return false }
            // A sibling app's own bundle is a live install, not a leftover. These
            // rows are review-only, but a deliberate section-checkbox click
            // selects review-only rows too.
            if otherAppPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
            if path.hasPrefix("/System/") || ScanExclusions.isInTrash(path) { return false }
            if !includeSystem, !path.hasPrefix(homePath + "/") { return false }
            if isLikelyDeveloperPath(path) { return false }
            // `~/Library` and `/Library` are in scope now, which is exactly where
            // the protected names live, so this path needs the same guard the
            // catalog walk applies.
            if FileMatcher.isProtected(url: url) { return false }
            if isCovered(path, by: seenPaths) || ScanExclusions.isExcluded(url, in: excluded) { return false }

            let name = url.lastPathComponent
            // Only bundles carry an indexed identifier, and only opaque names
            // cannot be judged lexically, so the metadata read is limited to them
            // instead of every filename the substring query returned.
            let needsMetadata = isCodeBundle(name) || FileMatcher.looksOpaque(name)
            return associates(name, descriptor)
                || (needsMetadata && FileMatcher.metadataBundleID(of: url)
                    .map { FileMatcher.containerMatches(identifier: $0, descriptor: descriptor) } == true)
        }

        let sorted = accepted.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }

        let fm = FileManager.default
        let appTeam = app.teamID ?? CodeSigning.teamID(of: app.url)
        return kept.compactMap { path -> FileItem? in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let url = URL(fileURLWithPath: path)
            if let appTeam, isCodeBundle(path),
               let team = CodeSigning.teamID(of: url), team != appTeam { return nil }
            let domain: FileDomain = path.hasPrefix(homePath + "/") ? .user : .system
            return FileItem(
                url: url,
                category: category,
                domain: domain,
                isDirectory: isDirectory.boolValue,
                isAutoSelectable: false
            )
        }
    }

    /// One metadata query rather than one process per term. Bundle identifiers are
    /// searched both as filenames (`com.vendor.App.plist`) and as code metadata.
    static func metadataQuery(for descriptor: AppDescriptor) -> String? {
        var nameSignals = Set(FileMatcher.vendorTokens(descriptor))
        nameSignals.formUnion(nameTerms(descriptor))
        nameSignals.formUnion(descriptor.allBundleIDs)

        var predicates = nameSignals.sorted().map {
            "kMDItemFSName == \"*\(escapeQueryValue($0))*\"cd"
        }
        predicates += descriptor.allBundleIDs
            .filter { $0.contains(".") }
            .sorted()
            .map { "kMDItemCFBundleIdentifier == \"\(escapeQueryValue($0))*\"cd" }
        guard !predicates.isEmpty else { return nil }
        return predicates.map { "(\($0))" }.joined(separator: " || ")
    }

    /// Run one `mdfind` query and parse its NUL-separated paths. Shared with
    /// `AppFinder`, which queries the same index for app bundles.
    static func mdfindPaths(_ query: String, isCancelled: (() -> Bool)? = nil) -> [URL] {
        guard FileManager.default.isExecutableFile(atPath: mdfind) else { return [] }
        let output = CommandRunner.run(mdfind, ["-0", query], isCancelled: isCancelled)
        guard output.ok else { return [] }
        return output.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL }
    }

    /// The catalog walk lists folders, and Spotlight indexes their contents, so a
    /// candidate under a listed parent would become a second row — and the hero
    /// total would count those bytes twice. Only descendants are collapsed; a
    /// candidate that is an *ancestor* of a catalogued row is still kept.
    private static func isCovered(_ path: String, by seenPaths: Set<String>) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if seenPaths.contains(url.path) { return true }
            url = url.deletingLastPathComponent()
        }
        return false
    }

    private static func escapeQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A signed code-bundle path whose Team ID is worth checking for ownership.
    static func isCodeBundle(_ path: String) -> Bool {
        let lower = path.lowercased()
        let exts = [".app", ".appex", ".xpc", ".framework", ".bundle", ".plugin", ".kext", ".systemextension"]
        return exts.contains { lower.hasSuffix($0) }
    }

    /// Association test for Spotlight hits: a full bundle id in the name, a
    /// reverse-DNS namespace hit (`com.parallels.`), or a WHOLE token equal to a
    /// vendor token or a distinctive app-name token. Whole-token (not prefix)
    /// avoids "ParallelSession"/"ParallelSCSIReporter"; the developer-path filter
    /// (`isLikelyDeveloperPath`) drops source-tree noise that name matching can
    /// pull in. Internal for unit testing.
    static func associates(_ name: String, _ descriptor: AppDescriptor) -> Bool {
        let lower = name.lowercased()
        for bid in descriptor.allBundleIDs where bid.contains(".") && lower.contains(bid) { return true }
        for namespace in FileMatcher.vendorNamespaces(descriptor) where lower.contains(namespace) { return true }
        let tokens = Set(lower.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        for vendor in FileMatcher.vendorTokens(descriptor) where tokens.contains(vendor) { return true }
        for term in nameTerms(descriptor) where tokens.contains(term) { return true }
        return false
    }

    /// Paths under a source checkout / build tree, where a name match almost
    /// always means code rather than an app leftover. Internal for unit testing.
    static func isLikelyDeveloperPath(_ path: String) -> Bool {
        let markers = [
            "/Developer/", "/node_modules/", "/.git/", "/Sources/", "/src/",
            "/Pods/", "/.build/", "/DerivedData/", "/.cargo/", "/.rustup/",
            "/go/pkg/", "/vendor/", "/dist/", "/target/", "/.venv/", "/site-packages/",
        ]
        return markers.contains { path.contains($0) }
    }

    /// Distinctive names declared by the bundle. Executable and alternate names
    /// matter for apps whose installed data does not use the display name.
    private static func nameTerms(_ descriptor: AppDescriptor) -> [String] {
        var sources = [descriptor.name] + descriptor.extraNames
        if let executable = descriptor.executable { sources.append(executable) }
        var terms: [String] = []
        for name in sources { appendNameTerms(name, to: &terms) }
        return terms
    }

    /// Every term becomes a `*substring*` query, so five characters is the floor
    /// for the ones derived from a name: "code" from Visual Studio Code would
    /// claim `~/code`. Vendor tokens and bundle ids carry their own floors and go
    /// into the query directly.
    private static func appendNameTerms(_ name: String, to terms: inout [String]) {
        let candidates = [name] + name.split { $0 == " " || $0 == "-" || $0 == "_" }.map(String.init)
        for candidate in candidates {
            let normalized = FileMatcher.normalize(candidate)
            if normalized.count >= 5,
               !genericNameWords.contains(normalized),
               !terms.contains(normalized) {
                terms.append(normalized)
            }
        }
    }

    private static let genericNameWords: Set<String> = [
        "notes", "mail", "store", "music", "video", "photos", "files", "home",
        "cloud", "drive", "player", "manager", "desktop", "studio", "helper",
        "server", "client", "editor", "viewer", "browser", "setup", "installer",
        "update", "settings", "system", "finder", "safari", "terminal", "calendar",
        "reminders", "contacts", "messages", "maps", "news", "stocks", "weather",
        "console", "monitor", "utility", "tools", "preview", "automator",
    ]
}
