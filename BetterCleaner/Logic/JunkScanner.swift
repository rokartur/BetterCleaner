import Foundation

/// Broad, app-independent reclaimable-space scanner — the "System Junk" view.
///
/// Unlike `LeftoverScanner` (one app's files) and `OrphanScanner` (files of
/// uninstalled apps), this surfaces *all* regenerable junk: per-app caches,
/// logs, saved window state, developer caches, and (opt-in) iOS backups and
/// system caches. Everything routes to the Trash, so it's recoverable.
///
/// Clearly-safe, app-regenerated categories (caches, logs, saved state, dev
/// caches) are pre-selected; heavyweight/destructive ones (backups, updates,
/// system dirs) are surfaced but left unchecked.
enum JunkScanner {
    private enum Mode {
        /// Each immediate child of the directory is its own removable item.
        case contents
        /// The directory itself is one removable item.
        case whole
    }

    private struct JunkLocation {
        let category: String
        let url: URL
        let domain: FileDomain
        let mode: Mode
        let safeDefault: Bool
    }

    /// Display order for the grouped result, biggest-impact-first.
    private static let categoryOrder = [
        "User Caches", "Saved Application State", "User Logs", "Developer",
        "iOS Backups", "iOS Software Updates", "System Caches", "System Logs",
    ]

    private static func catalog(includeSystem: Bool) -> [JunkLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func u(_ sub: String) -> URL { home.appendingPathComponent(sub, isDirectory: true) }

        var list: [JunkLocation] = [
            JunkLocation(category: "User Caches", url: u("Library/Caches"), domain: .user, mode: .contents, safeDefault: true),
            JunkLocation(category: "Saved Application State", url: u("Library/Saved Application State"), domain: .user, mode: .contents, safeDefault: true),
            JunkLocation(category: "User Logs", url: u("Library/Logs"), domain: .user, mode: .contents, safeDefault: true),
            // Heavyweight, recoverable but rarely wanted by default.
            JunkLocation(category: "iOS Backups", url: u("Library/Application Support/MobileSync/Backup"), domain: .user, mode: .contents, safeDefault: false),
            JunkLocation(category: "iOS Software Updates", url: u("Library/iTunes/iPhone Software Updates"), domain: .user, mode: .contents, safeDefault: false),
        ]

        // Developer caches (reuse the Development catalog), pre-selected.
        for loc in DevLocations.all() {
            list.append(JunkLocation(category: "Developer", url: URL(fileURLWithPath: loc.path), domain: .user, mode: .whole, safeDefault: true))
        }

        if includeSystem {
            list.append(JunkLocation(category: "System Caches", url: URL(fileURLWithPath: "/Library/Caches", isDirectory: true), domain: .system, mode: .contents, safeDefault: false))
            list.append(JunkLocation(category: "System Logs", url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true), domain: .system, mode: .contents, safeDefault: false))
        }
        return list
    }

    /// Scan synchronously (run off the main thread; it walks the file system).
    static func scan(includeSystem: Bool, excluded: Set<String> = []) -> [ScanSection] {
        let fm = FileManager.default
        let locations = catalog(includeSystem: includeSystem)

        // The catalog roots are independent subtrees and the dominant cost is the
        // recursive FileSize walk per item, so gather each location's items in
        // parallel (one slot per location, no shared state during the walk)…
        var perLocation = [[FileItem]](repeating: [], count: locations.count)
        perLocation.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: locations.count) { i in
                buffer[i] = items(for: locations[i], excluded: excluded, fm: fm)
            }
        }

        // …then merge serially in catalog order, de-duping by standardized path
        // (first location wins — same precedence the old serial loop produced).
        var grouped: [String: [FileItem]] = [:]
        var seen = Set<String>()
        for items in perLocation {
            for item in items where seen.insert(item.url.standardizedFileURL.path).inserted {
                grouped[item.category, default: []].append(item)
            }
        }

        var sections: [ScanSection] = []
        for category in categoryOrder {
            if let items = grouped.removeValue(forKey: category), !items.isEmpty {
                sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
            }
        }
        for (category, items) in grouped.sorted(by: { $0.key < $1.key }) {
            sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
        }
        return sections
    }

    /// All removable items for one catalog location (sizes computed here). Pure —
    /// no shared state — so it is safe to call concurrently across locations.
    private static func items(for loc: JunkLocation, excluded: Set<String>, fm: FileManager) -> [FileItem] {
        switch loc.mode {
        case .whole:
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: loc.url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
            if ScanExclusions.isExcluded(loc.url, in: excluded) { return [] }
            return makeItem(loc.url, isDir: true, loc: loc).map { [$0] } ?? []

        case .contents:
            guard let entries = try? fm.contentsOfDirectory(
                at: loc.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var out: [FileItem] = []
            for url in entries {
                if FileMatcher.isProtected(url: url) { continue }
                if ScanExclusions.isExcluded(url, in: excluded) { continue }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if let item = makeItem(url, isDir: isDir.boolValue, loc: loc) { out.append(item) }
            }
            return out
        }
    }

    private static func makeItem(_ url: URL, isDir: Bool, loc: JunkLocation) -> FileItem? {
        let size = FileSize.size(of: url)
        guard size > 0 else { return nil }
        // `safeDefault` drives BOTH pre-selection and auto-selectability so the
        // green "safe" dot, the "Select Safe" button, and the sidebar reclaimable
        // badge all agree: only recreatable categories (caches/logs/saved state)
        // count as safe — iOS Backups / System Caches stay amber and opt-in.
        return FileItem(url: url, category: loc.category, domain: loc.domain,
                        isDirectory: isDir, size: size,
                        isSelected: loc.safeDefault, isAutoSelectable: loc.safeDefault)
    }
}
