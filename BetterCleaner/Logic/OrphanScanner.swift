import Foundation

/// Results are graded by confidence and never pre-selected:
///  - **High**: a launchd job (agent/daemon) whose `Program` path no longer
///    exists — an unambiguous leftover of a deleted app, even if the label isn't
///    reverse-DNS. Eligible for "Select All".
///  - **Medium**: a reverse-DNS-named file/folder (or UUID container resolved via
///    metadata) that no installed app owns.
///  - **Low**: an app-named `Application Support` folder matching no installed
///    app and not on the shared-vendor allowlist.
enum OrphanScanner {
    enum Confidence: Int, CaseIterable {
        case high = 0, medium = 1, low = 2

        var category: String {
            switch self {
            case .high: return "Orphans (High confidence)"
            case .medium: return "Orphans (Medium confidence)"
            case .low: return "Orphans (Low confidence)"
            }
        }
    }

    /// Directories whose reverse-DNS entries are high-signal enough to grade.
    private static let dirCategories: Set<String> = [
        "Application Support", "Caches", "Preferences", "Containers",
        "Group Containers", "Saved Application State", "HTTPStorages",
        "Logs", "WebKit", "Application Scripts",
    ]

    /// Only here do we trust a *name* (non-reverse-DNS) match, since these folders
    /// are conventionally named after the app's display name.
    private static let nameBasedCategories: Set<String> = ["Application Support"]

    /// Normalized folder names that are shared across apps/vendors (or are system
    /// state) and must never be flagged as orphans on a name match alone.
    static let vendorAllowlist: Set<String> = [
        "google", "microsoft", "adobe", "mozilla", "apple", "comapple",
        "crashreporter", "mobilesync", "caches", "logs", "preferences",
        "containers", "groupcontainers", "knowledge", "icloud", "homebrew",
        "java", "jetbrains", "steam", "epicgames", "discord",
    ]

    static func scan(
        index: InstalledAppsIndex,
        exclusions: [URL],
        includeSystem: Bool,
        progress: ((Double) -> Void)? = nil
    ) -> [FileItem] {
        let excluded = Set(exclusions.map { $0.standardizedFileURL.path })
        var results: [FileItem] = []
        var seen = Set<String>()

        progress?(0.1)
        appendBrokenLaunchOrphans(includeSystem: includeSystem, excluded: excluded, seen: &seen, into: &results)
        progress?(0.35)
        appendDirectoryOrphans(index: index, includeSystem: includeSystem, excluded: excluded, seen: &seen, into: &results)
        progress?(0.7)
        // Stale installer receipts (app bundle gone) — only when scanning system,
        // since they live in /var/db/receipts and remove via the privileged batch.
        if includeSystem {
            appendOrphanReceipts(index: index, excluded: excluded, seen: &seen, into: &results)
        }
        progress?(1.0)
        return results
    }

    /// Grade a directory entry, or nil if it isn't an orphan. Pure — no file
    /// system — so the confidence rules can be unit-tested. `resolvedID` is the
    /// reverse-DNS id recovered from the name (or container metadata), else the
    /// raw name.
    static func classify(name: String, resolvedID: String, isDirectory: Bool, category: String, index: InstalledAppsIndex) -> Confidence? {
        if isReverseDNS(resolvedID) {
            if index.ownsIdentifier(resolvedID) || index.matchesName(resolvedID) { return nil }
            return .medium
        }
        // Name-based: only app-named directories, never a bare common word.
        guard nameBasedCategories.contains(category), isDirectory else { return nil }
        let norm = FileMatcher.normalize(name)
        guard norm.count >= 4, !vendorAllowlist.contains(norm) else { return nil }
        if index.matchesName(name) { return nil }
        return .low
    }

    // MARK: - Broken-reference launch items (high confidence)

    private static func appendBrokenLaunchOrphans(
        includeSystem: Bool,
        excluded: Set<String>,
        seen: inout Set<String>,
        into results: inout [FileItem]
    ) {
        let fm = FileManager.default
        for item in LaunchDaemonScanner.scan(includeSystem: includeSystem) where item.isRemovable {
            let std = item.url.standardizedFileURL.path
            if excluded.contains(std) || seen.contains(std) { continue }
            if FileMatcher.isProtected(url: item.url) { continue }
            // Only an *absolute* program path we can definitively check; a missing
            // one means the app it launched is gone.
            guard let program = LaunchDaemonScanner.programPath(of: item.url), program.hasPrefix("/") else { continue }
            if fm.fileExists(atPath: program) { continue }

            seen.insert(std)
            let (size, complete) = FileSize.sizeWithStatus(of: item.url)
            results.append(FileItem(
                url: item.url,
                category: Confidence.high.category,
                domain: item.domain,
                isDirectory: false,
                size: size,
                isSelected: false,
                sizeIsApproximate: !complete,
                isAutoSelectable: true
            ))
        }
    }

    // MARK: - Directory orphans (medium / low confidence)

    private static func appendDirectoryOrphans(
        index: InstalledAppsIndex,
        includeSystem: Bool,
        excluded: Set<String>,
        seen: inout Set<String>,
        into results: inout [FileItem]
    ) {
        let fm = FileManager.default
        let locations = Locations.locations(includeSystem: includeSystem).filter { dirCategories.contains($0.category) }

        for location in locations {
            guard let entries = try? fm.contentsOfDirectory(
                at: location.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries {
                let std = url.standardizedFileURL.path
                if excluded.contains(std) || seen.contains(std) { continue }
                if FileMatcher.isProtected(url: url) { continue }

                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)

                var resolved = identifier(from: url.lastPathComponent)
                if !isReverseDNS(resolved), location.resolvesContainerID,
                   let cid = FileMatcher.containerIdentifier(of: url) {
                    resolved = cid
                }

                guard let confidence = classify(
                    name: url.lastPathComponent,
                    resolvedID: resolved,
                    isDirectory: isDir.boolValue,
                    category: location.category,
                    index: index
                ) else { continue }

                seen.insert(std)
                let (size, complete) = FileSize.sizeWithStatus(of: url)
                results.append(FileItem(
                    url: url,
                    category: confidence.category,
                    domain: location.domain,
                    isDirectory: isDir.boolValue,
                    size: size,
                    isSelected: false,
                    sizeIsApproximate: !complete,
                    isAutoSelectable: confidence == .high
                ))
            }
        }
    }

    /// Strip a trailing known extension to recover the bundle-id-like stem.
    private static func identifier(from name: String) -> String {
        for ext in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    /// Reverse-DNS = contains a dot and isn't a hidden dotfile.
    static func isReverseDNS(_ s: String) -> Bool {
        guard !s.hasPrefix(".") else { return false }
        guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return false }
        return true
    }

    // MARK: - Orphan package receipts (medium confidence)

    /// Installer receipts whose app bundle is gone. A non-Apple receipt whose BOM
    /// names a top-level `.app` that no longer exists on disk — and which no
    /// installed app owns by id — is a stale leftover of a removed installer. It's
    /// surfaced (medium, review-only) as its `.plist`/`.bom` files, which the
    /// Orphaned view trashes through the privileged batch. Receipts that install no
    /// `.app` (CLI tools, drivers, preference panes) are never judged — conservative,
    /// since their installed files may still be in use. Needs Full Disk Access to
    /// read `/var/db/receipts`; without it the BOM read is empty and nothing flags.
    private static func appendOrphanReceipts(
        index: InstalledAppsIndex,
        excluded: Set<String>,
        seen: inout Set<String>,
        into results: inout [FileItem]
    ) {
        let fm = FileManager.default
        for id in PackageScanner.nonSystemPackageIDs() {
            if index.ownsIdentifier(id) { continue }
            let appPaths = topLevelAppPaths(PackageScanner.bomFiles(id: id))
            guard !appPaths.isEmpty else { continue }
            if appPaths.contains(where: { fm.fileExists(atPath: $0) }) { continue }
            for url in PackageScanner.receiptPaths(id: id) {
                let std = url.standardizedFileURL.path
                if excluded.contains(std) || seen.contains(std) { continue }
                seen.insert(std)
                let (size, complete) = FileSize.sizeWithStatus(of: url)
                results.append(FileItem(
                    url: url,
                    category: Confidence.medium.category,
                    domain: .system,
                    isDirectory: false,
                    size: size,
                    isSelected: false,
                    sizeIsApproximate: !complete,
                    isAutoSelectable: false,
                    title: "Receipt · \(id)"
                ))
            }
        }
    }

    /// The top-level `.app` bundle paths referenced by a package's BOM file list
    /// (".../Foo.app/Contents/MacOS/Foo" → "/Applications/Foo.app"). Internal for
    /// unit testing.
    static func topLevelAppPaths(_ files: [URL]) -> Set<String> {
        var apps = Set<String>()
        for url in files {
            let p = url.path
            if let r = p.range(of: ".app/") {
                apps.insert(String(p[..<r.lowerBound]) + ".app")
            } else if p.hasSuffix(".app") {
                apps.insert(p)
            }
        }
        return apps
    }
}
