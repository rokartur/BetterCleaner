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
    static func scan(app: InstalledApp, seenPaths: Set<String>, isCancelled: () -> Bool = { false }) -> [FileItem] {
        guard FileManager.default.isExecutableFile(atPath: mdfind) else { return [] }
        if isCancelled() { return [] }
        let descriptor = app.descriptor

        // Query by reverse-DNS signals (vendor tokens, bundle ids) AND distinctive
        // app-name tokens. Name matching catches leftovers named after the app in
        // non-standard places; near-name source noise (e.g. ~/Developer/discord-*.
        // tsx) is dropped by the developer-path filter below, and everything here
        // is review-only (never auto-selected).
        var terms = Set(FileMatcher.vendorTokens(descriptor))
        terms.formUnion(nameTerms(descriptor))

        // The argv "tail" of each Spotlight query (name term or bundle-id metadata,
        // the latter catching helper .apps the vendor registered).
        var queryTails: [[String]] = terms.map { ["-name", $0] }
        for bid in descriptor.allBundleIDs where bid.contains(".") {
            queryTails.append(["kMDItemCFBundleIdentifier == '\(bid)*'c"])
        }

        // Search scopes. The unscoped pass (`nil`) hits the whole local index —
        // boot volume + every Spotlight-indexed volume. The `-onlyin` passes force
        // a deterministic sweep of external volumes and the shared folder, which a
        // broad name query can rank-drop or which may be freshly mounted. Volumes
        // the user excluded from indexing (Time Machine / backup drives) stay
        // invisible by design — no query scope can reach an unindexed store.
        let scopes: [String?] = [nil] + extraVolumeScopes()

        // Each mdfind is an independent Process + Spotlight query; run them
        // concurrently and merge hits under a lock. `-0` makes mdfind NUL-delimit
        // output so paths containing newlines (legal on APFS/HFS+) aren't split.
        var queries: [[String]] = []
        for scope in scopes {
            let prefix = scope.map { ["-0", "-onlyin", $0] } ?? ["-0"]
            for tail in queryTails { queries.append(prefix + tail) }
        }

        var candidates = Set<String>()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: queries.count) { i in
            if isCancelled() { return }
            let out = CommandRunner.run(mdfind, queries[i])
            guard out.ok else { return }
            var local: [String] = []
            for field in out.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
                let path = String(field)
                if !path.isEmpty { local.append(path) }
            }
            guard !local.isEmpty else { return }
            lock.lock()
            for path in local { candidates.insert(path) }
            lock.unlock()
        }

        if isCancelled() { return [] }
        let appPath = app.url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let userLibrary = Locations.userLibrary.standardizedFileURL.path
        let systemLibrary = Locations.systemLibrary.standardizedFileURL.path

        let accepted = candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { path in
                let name = (path as NSString).lastPathComponent
                // Attribute by name/vendor/bundle-id in the name, OR — for an
                // opaque (UUID/hash) folder a name test can't read, e.g. a data
                // dir on an external volume — by its Spotlight-indexed bundle id.
                // Routes through FileMatcher (one matcher), never a parallel rule.
                let attributed = associates(name, descriptor)
                    || (FileMatcher.looksOpaque(name)
                        && FileMatcher.metadataBundleID(of: URL(fileURLWithPath: path))
                            .map { FileMatcher.containerMatches(identifier: $0, descriptor: descriptor) } == true)
                guard attributed else { return false }
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
        // The scanned app's Team ID is read lazily here (bulk discovery skips it):
        // it's the negative-evidence baseline for rejecting same-named bundles from
        // a different publisher.
        let appTeam = app.teamID ?? CodeSigning.teamID(of: app.url)
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

    /// Extra `-onlyin` scopes for the Spotlight sweep beyond the default (whole
    /// local index): the shared folder plus each mounted external volume under
    /// `/Volumes`, skipping the boot volume (its `/Volumes` entry is a symlink to
    /// `/`, already covered by the unscoped pass). Gives a deterministic per-volume
    /// sweep for app data that lives off the boot drive.
    private static func extraVolumeScopes() -> [String] {
        let fm = FileManager.default
        var scopes: [String] = []
        let shared = "/Users/Shared"
        if fm.fileExists(atPath: shared) { scopes.append(shared) }
        if let vols = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for vol in vols {
                let path = "/Volumes/" + vol
                // Skip the boot-volume symlink (resolves to "/").
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                if resolved == "/" { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                scopes.append(path)
            }
        }
        return scopes
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
