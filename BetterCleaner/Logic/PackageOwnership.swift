import Foundation

/// Ground-truth ownership from installer receipts: which files an app's `.pkg`
/// actually wrote, per its Bill of Materials (BOM).
///
/// The lexical matcher (`FileMatcher`) infers ownership from names and bundle ids
/// — strong, but a heuristic. For pkg-installed apps the BOM is *authoritative*:
/// it lists the exact paths the installer laid down, with no false positives and
/// no name-based misses. `LeftoverScanner` folds these in as pre-selected,
/// de-duped against the lexical results, so the BOM only *adds* the installer
/// files an app-name/bundle-id walk can't see (oddly-named data files, daemon
/// configs in non-vendor directories, helpers without the app's name).
///
/// The app→package association is itself ground truth: a package owns the app when
/// its BOM lists the app's own `.app` bundle. The index is built once per session
/// (every non-Apple BOM read concurrently) and reused, since receipts rarely
/// change while the app is open.
enum PackageOwnership {
    private static let lock = NSLock()
    private static var cached: [String: [URL]]?

    /// The installer-written files owned by `app` (its package's BOM, minus the app
    /// bundle itself, which the scanner adds separately). Already safety-filtered
    /// and bundle-collapsed by `PackageBOMFilter`. Empty for drag-installed apps
    /// (no receipt) and when receipts can't be read.
    static func ownedFiles(for app: InstalledApp) -> [URL] {
        let key = app.url.standardizedFileURL.path.lowercased()
        let appPath = app.url.standardizedFileURL.path
        let files = index()[key] ?? []
        guard !files.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [URL] = []
        for url in files {
            let std = url.standardizedFileURL.path
            if std == appPath { continue }
            if seen.insert(std).inserted { out.append(url) }
        }
        return out
    }

    /// Drop the cached index so the next lookup rebuilds it — call after an
    /// uninstall/forget that changes the receipt store.
    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }

    /// App-bundle path (lowercased, standardized) → the files of every non-Apple
    /// package whose BOM installs that bundle. Built once, then cached.
    private static func index() -> [String: [URL]] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let built = build()
        cached = built
        return built
    }

    private static func build() -> [String: [URL]] {
        guard PackageScanner.isAvailable() else { return [:] }
        let ids = PackageScanner.nonSystemPackageIDs()
        guard !ids.isEmpty else { return [:] }

        // Read each package's BOM once, concurrently (independent lsbom spawns,
        // disjoint slot writes) — mirrors PackageScanner.scan's fan-out.
        var per = [(apps: [String], files: [URL])](repeating: ([], []), count: ids.count)
        per.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                let files = PackageScanner.bomFiles(id: ids[i])
                let apps = OrphanScanner.topLevelAppPaths(files)
                buffer[i] = (Array(apps), files)
            }
        }

        var map: [String: [URL]] = [:]
        for entry in per where !entry.apps.isEmpty {
            for app in entry.apps {
                let key = URL(fileURLWithPath: app).standardizedFileURL.path.lowercased()
                map[key, default: []].append(contentsOf: entry.files)
            }
        }
        return map
    }
}
