import Foundation

/// Recall layer beyond the fixed Library catalog: asks Spotlight (`mdfind`) for
/// app-associated files anywhere on disk, surfacing leftovers in non-standard
/// places — `~/Applications (Vendor)`, `/Users/Shared/<App>`, stray files in the
/// home folder, VM/data bundles, etc.
///
/// Deliberately conservative: results are **never auto-selected** (they can
/// include large user data such as virtual machines), are filtered with a tight
/// association test (exact vendor token / bundle-id / reverse-DNS namespace — so
/// "ParallelSession.pm" or "ParallelSCSIReporter" never match), and exclude
/// everything already covered by the Library scan.
enum SpotlightScanner {
    private static let mdfind = "/usr/bin/mdfind"
    static let category = "Found by Spotlight"

    /// Find app-associated paths outside the scanned Library locations.
    /// `seenPaths` are standardized paths already surfaced by the Library scan.
    static func scan(app: InstalledApp, seenPaths: Set<String>) -> [FileItem] {
        guard FileManager.default.isExecutableFile(atPath: mdfind) else { return [] }
        let descriptor = app.descriptor

        // Query by reverse-DNS signals (vendor tokens, bundle ids) AND distinctive
        // app-name tokens. Name matching catches leftovers named after the app in
        // non-standard places; near-name source noise (e.g. ~/Developer/discord-*.
        // tsx) is dropped by the developer-path filter below, and everything here
        // is review-only (never auto-selected).
        var terms = Set(FileMatcher.vendorTokens(descriptor))
        terms.formUnion(nameTerms(descriptor))

        // Each mdfind is an independent Process + Spotlight query. Build the full
        // query list (name terms + bundle-id metadata, the latter catching helper
        // .apps the vendor registered) and run them concurrently instead of one
        // serial spawn at a time, merging hits under a lock.
        var queries: [[String]] = terms.map { ["-name", $0] }
        for bid in descriptor.allBundleIDs where bid.contains(".") {
            queries.append(["kMDItemCFBundleIdentifier == '\(bid)*'c"])
        }

        var candidates = Set<String>()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: queries.count) { i in
            let out = CommandRunner.run(mdfind, queries[i])
            guard out.ok else { return }
            var local: [String] = []
            for line in out.stdout.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { local.append(path) }
            }
            guard !local.isEmpty else { return }
            lock.lock()
            for path in local { candidates.insert(path) }
            lock.unlock()
        }

        let appPath = app.url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let userLibrary = Locations.userLibrary.standardizedFileURL.path
        let systemLibrary = Locations.systemLibrary.standardizedFileURL.path

        let accepted = candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { path in
                let name = (path as NSString).lastPathComponent
                guard associates(name, descriptor) else { return false }
                if seenPaths.contains(path) { return false }
                if path == appPath || path.hasPrefix(appPath + "/") { return false }
                // Library + System are already covered by the catalog scan.
                if path.hasPrefix(userLibrary + "/") || path.hasPrefix(systemLibrary + "/") { return false }
                if path.hasPrefix("/System/") { return false }
                // Trashed items — including a bundle BetterCleaner just uninstalled,
                // which Spotlight still indexes at its ~/.Trash path — are already
                // gone; never re-surface them as leftovers.
                if ScanExclusions.isInTrash(path) { return false }
                // Source/checkout trees: a name like "discord" matches code files;
                // these aren't app leftovers.
                if isLikelyDeveloperPath(path) { return false }
                return true
            }

        // Keep only top-most accepted ancestors (drop children of a kept path).
        let sorted = accepted.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }

        let fm = FileManager.default
        let appTeam = app.teamID
        return kept.compactMap { path -> FileItem? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            let url = URL(fileURLWithPath: path)
            // Negative evidence: a signed bundle whose Team ID differs from the app
            // being removed belongs to a different publisher — not its leftover, even
            // if the name matches. Only rejects when both teams are known (an
            // unsigned or teamless candidate is kept, since these are review-only).
            if let appTeam, isCodeBundle(path), let team = CodeSigning.teamID(of: url), team != appTeam {
                return nil
            }
            let (size, complete) = FileSize.sizeWithStatus(of: url)
            let domain: FileDomain = path.hasPrefix(homePath + "/") ? .user : .system
            // Never auto-selected: may be large user data (e.g. virtual machines).
            return FileItem(url: url, category: category, domain: domain, isDirectory: isDir.boolValue,
                            size: size, isSelected: false, sizeIsApproximate: !complete, isAutoSelectable: false)
        }
        .sorted { $0.size > $1.size }
    }

    /// A signed code-bundle path whose Team ID is worth checking for ownership.
    static func isCodeBundle(_ path: String) -> Bool {
        let exts = [".app", ".appex", ".xpc", ".framework", ".bundle", ".plugin", ".kext", ".systemextension"]
        return exts.contains { path.hasSuffix($0) }
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

    /// Distinctive, normalized app-name tokens to search by: the full normalized
    /// name plus its individual words, skipping generic words that would flood
    /// results ("notes", "mail", "manager", …).
    private static func nameTerms(_ descriptor: AppDescriptor) -> [String] {
        var terms: [String] = []
        let full = FileMatcher.normalize(descriptor.name)
        if full.count >= 5, !genericNameWords.contains(full) { terms.append(full) }
        for word in descriptor.name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }) {
            let normalized = FileMatcher.normalize(String(word))
            if normalized.count >= 5, !genericNameWords.contains(normalized), !terms.contains(normalized) {
                terms.append(normalized)
            }
        }
        return terms
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
