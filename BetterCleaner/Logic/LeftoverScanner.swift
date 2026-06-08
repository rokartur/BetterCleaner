import Foundation

/// A category group of scan results, ready for the outline view.
struct ScanSection {
    let category: String
    var items: [FileItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Finds the files associated with a single installed app.
enum LeftoverScanner {
    /// Scan synchronously. Callers should run this off the main thread; it walks
    /// the file system and computes sizes.
    /// Scan for an app's leftovers. `otherApps` (the rest of the installed apps)
    /// lets vendor-only ("weak") matches be auto-selected **only** when the
    /// vendor is exclusive to this app — so "Parallels"/`com.parallels.*` are
    /// selected for the sole Parallels app, but a shared "Google" folder stays
    /// manual when several `com.google.*` apps are installed.
    static func scan(app: InstalledApp, sensitivity: SearchSensitivity, includeSystem: Bool, otherApps: [InstalledApp] = [], excluded: Set<String> = [], conditions: [UserCondition] = [], progress: ((Double) -> Void)? = nil) -> [FileItem] {
        let fm = FileManager.default
        let descriptor = app.descriptor
        var results: [FileItem] = []
        var seen = Set<String>()

        let promoteVendor = vendorIsExclusive(app: app, otherApps: otherApps)
        // User include/exclude rules, compiled once for this app.
        let evaluator = ConditionEvaluator(conditions: conditions, descriptor: descriptor)

        let locations = Locations.locations(includeSystem: includeSystem) + Locations.perUserTempLocations()
        // +3 trailing phases: receipts, CLI tools, Spotlight.
        let totalSteps = Double(locations.count + 3)
        var doneSteps = 0.0
        func tick() {
            doneSteps += 1
            progress?(min(doneSteps / totalSteps, 0.99))
        }
        progress?(0)

        // The app bundle itself (only when user-removable — never /System apps).
        if !app.isSystem {
            let std = app.url.standardizedFileURL.path
            seen.insert(std)
            let (size, complete) = FileSize.sizeWithStatus(of: app.url)
            results.append(FileItem(url: app.url, category: "Application", domain: .user, isDirectory: true, size: size, isSelected: true, sizeIsApproximate: !complete))
        }

        for location in locations {
            collect(
                in: location.url,
                category: location.category,
                domain: location.domain,
                descriptor: descriptor,
                sensitivity: sensitivity,
                resolvesContainerID: location.resolvesContainerID,
                depth: location.depth,
                // Weak (vendor name) matching stays shallow (≤2); deeper levels
                // record strong signals only.
                weakDepth: min(location.depth, 2),
                autoSelectable: location.autoSelectable,
                promoteVendor: promoteVendor,
                excluded: excluded,
                conditions: evaluator,
                results: &results,
                seen: &seen,
                fm: fm
            )
            tick()
        }

        // Installer-package receipts owned by the app. Listing needs no admin;
        // forgetting them happens in AppRemover. De-duplicated against `seen`.
        defer { progress?(1.0) }
        for item in ReceiptScanner.fileItems(for: descriptor) {
            let std = item.url.standardizedFileURL.path
            if seen.insert(std).inserted { results.append(item) }
        }
        tick()

        // CLI symlinks the app dropped in /usr/local/{bin,sbin} (e.g. prlctl).
        for item in cliToolItems(for: app) {
            let std = item.url.standardizedFileURL.path
            if seen.insert(std).inserted { results.append(item) }
        }
        tick()

        // Spotlight recall: app-associated files outside the Library catalog
        // (~/Applications (Vendor), /Users/Shared, home, data bundles). Review-only
        // — never auto-selected, since these can include large user data.
        for item in SpotlightScanner.scan(app: app, seenPaths: seen) {
            let std = item.url.standardizedFileURL.path
            if seen.insert(std).inserted { results.append(item) }
        }
        tick()
        return results
    }

    /// Whether this app's vendor token(s) are used by no other installed app, so
    /// vendor-named leftovers ("Parallels", `com.parallels.*`) unambiguously
    /// belong to it and can be auto-selected. False (conservative) when the vendor
    /// is shared (e.g. several `com.google.*` apps) or unknown.
    private static func vendorIsExclusive(app: InstalledApp, otherApps: [InstalledApp]) -> Bool {
        let appVendors = Set(FileMatcher.vendorTokens(app.descriptor))
        guard !appVendors.isEmpty else { return false }
        let appPath = app.url.standardizedFileURL.path
        var otherVendors = Set<String>()
        for other in otherApps where other.url.standardizedFileURL.path != appPath {
            otherVendors.formUnion(FileMatcher.vendorTokens(other.descriptor))
        }
        return appVendors.isDisjoint(with: otherVendors)
    }

    /// Symlinks under `/usr/local/{bin,sbin}` whose target resolves inside the
    /// app bundle — CLI tools an installer added to PATH. A target inside the
    /// bundle is an unambiguous (strong) signal, so these are pre-selected.
    private static func cliToolItems(for app: InstalledApp) -> [FileItem] {
        let fm = FileManager.default
        let appPath = app.url.standardizedFileURL.path
        var items: [FileItem] = []
        for dir in ["/usr/local/bin", "/usr/local/sbin"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                let linkPath = dir + "/" + name
                // destinationOfSymbolicLink throws for non-symlinks → filters them.
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else { continue }
                let resolved = dest.hasPrefix("/")
                    ? URL(fileURLWithPath: dest).standardizedFileURL.path
                    : URL(fileURLWithPath: dir).appendingPathComponent(dest).standardizedFileURL.path
                guard resolved == appPath || resolved.hasPrefix(appPath + "/") else { continue }
                items.append(FileItem(url: URL(fileURLWithPath: linkPath), category: "Command Line Tools",
                                      domain: .system, isDirectory: false, size: 0, isSelected: true))
            }
        }
        return items
    }

    /// Walk one directory level, recording matches and descending into
    /// non-matching folders while `depth` remains. A matched folder is taken
    /// whole (no descent into it).
    private static func collect(
        in dir: URL,
        category: String,
        domain: FileDomain,
        descriptor: AppDescriptor,
        sensitivity: SearchSensitivity,
        resolvesContainerID: Bool,
        depth: Int,
        weakDepth: Int,
        autoSelectable: Bool,
        promoteVendor: Bool,
        excluded: Set<String>,
        conditions: ConditionEvaluator,
        results: inout [FileItem],
        seen: inout Set<String>,
        fm: FileManager
    ) {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            if FileMatcher.isProtected(url: url) { continue }
            // User scan exclusions skip the path (and its subtree) entirely.
            if ScanExclusions.isExcluded(url, in: excluded) { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            // User condition rules. Exclude drops the entry (and its subtree);
            // include can surface a file the built-in matcher misses.
            let decision = conditions.isEmpty
                ? ConditionEvaluator.Decision.none
                : conditions.decide(fileName: url.lastPathComponent, path: url.path)
            if decision == .forceExclude { continue }

            var strength = FileMatcher.match(fileName: url.lastPathComponent, descriptor: descriptor, sensitivity: sensitivity)
            if strength == nil, resolvesContainerID, isDir.boolValue,
               let cid = FileMatcher.containerIdentifier(of: url),
               FileMatcher.containerMatches(identifier: cid, descriptor: descriptor) {
                strength = .strong
            }
            // Opaque (UUID/hash) folders carry no lexical signal — ask Spotlight for
            // the owning bundle id. An id equal to one of the app's is anchored (no
            // false positives), so treat it as a strong, auto-selectable match. Gated
            // on `looksOpaque` so the metadata lookup runs only for nameless entries.
            if strength == nil, sensitivity != .strict, isDir.boolValue,
               FileMatcher.looksOpaque(url.lastPathComponent),
               let mdID = FileMatcher.metadataBundleID(of: url),
               FileMatcher.containerMatches(identifier: mdID, descriptor: descriptor) {
                strength = .strong
            }

            // Force-include a file the matcher would miss. Review-only: never
            // auto-selected, never for system-domain files, and never able to
            // resurrect a protected target (defensive re-check).
            if strength == nil, decision == .forceInclude, domain != .system,
               !FileMatcher.isProtected(url: url.resolvingSymlinksInPath()) {
                let std = url.standardizedFileURL.path
                if seen.insert(std).inserted {
                    let (size, complete) = FileSize.sizeWithStatus(of: url)
                    results.append(FileItem(
                        url: url,
                        category: category,
                        domain: domain,
                        isDirectory: isDir.boolValue,
                        size: size,
                        isSelected: false,
                        sizeIsApproximate: !complete,
                        isAutoSelectable: false
                    ))
                }
                continue // included folder taken whole — don't descend
            }

            if let strength {
                // Beyond the weak-match budget (deep levels) only strong signals
                // (bundle-id / vendor-namespace in the filename) are recorded — so
                // the deep walk catches com.parallels.* files nested under shared
                // containers (com.apple.sharedfilelist, CorePatch/Keychain) without
                // surfacing other apps' data or vendor-name noise.
                // Record: always for strong (bundle-id) matches; for vendor
                // (weak) matches when shallow (`weakDepth`) OR when the vendor is
                // exclusive to this app (`promoteVendor`) — then com.parallels.*
                // nested deep under shared containers is unambiguously ours.
                let isWeak = strength == .weak
                if !isWeak || weakDepth >= 1 || promoteVendor {
                    let std = url.standardizedFileURL.path
                    if seen.insert(std).inserted {
                        let (size, complete) = FileSize.sizeWithStatus(of: url)
                        // Weak (vendor-only) matches auto-select only when the vendor
                        // is exclusive to this app; otherwise they stay manual.
                        let confident = !isWeak || promoteVendor
                        let select = autoSelectable && confident
                        results.append(FileItem(
                            url: url,
                            category: category,
                            domain: domain,
                            isDirectory: isDir.boolValue,
                            size: size,
                            isSelected: select,
                            sizeIsApproximate: !complete,
                            isAutoSelectable: select
                        ))
                    }
                    continue // matched folder taken whole — don't descend
                }
                // Weak match past the weak budget: don't record; keep descending.
            }

            // No match (or deep weak): descend another level if budget remains.
            if depth > 1, isDir.boolValue {
                collect(
                    in: url,
                    category: category,
                    domain: domain,
                    descriptor: descriptor,
                    sensitivity: sensitivity,
                    resolvesContainerID: false,
                    depth: depth - 1,
                    weakDepth: max(weakDepth - 1, 0),
                    autoSelectable: autoSelectable,
                    promoteVendor: promoteVendor,
                    excluded: excluded,
                    conditions: conditions,
                    results: &results,
                    seen: &seen,
                    fm: fm
                )
            }
        }
    }

    /// Group a flat result list into ordered, size-sorted sections.
    static func sections(from items: [FileItem]) -> [ScanSection] {
        var grouped: [String: [FileItem]] = [:]
        for item in items { grouped[item.category, default: []].append(item) }

        var sections: [ScanSection] = []
        for category in Locations.categoryOrder {
            if let items = grouped.removeValue(forKey: category), !items.isEmpty {
                sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
            }
        }
        // Any categories not in the canonical order (defensive) go last.
        for (category, items) in grouped.sorted(by: { $0.key < $1.key }) {
            sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
        }
        return sections
    }
}
