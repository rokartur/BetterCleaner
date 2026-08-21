import Foundation

/// Installer-receipt evidence for files written alongside an application.
/// A receipt proves package ownership, not exclusive application ownership: one
/// package may install a suite. Shared-package files are therefore review-only,
/// and sibling application bundles are never offered for removal.
enum PackageOwnership {
    struct PackageRecord: Equatable {
        let id: String
        let files: [URL]
        let appPaths: [String]
    }

    struct OwnedFile: Equatable {
        let url: URL
        let isExclusiveToApp: Bool
    }

    struct Result: Equatable {
        let files: [OwnedFile]
        let removableReceiptIDs: [String]
        /// Receipts this app appears in that also own a sibling application, so
        /// `pkgutil --forget` must not be offered for them.
        let sharedReceiptIDs: [String]
    }

    private static let lock = NSLock()
    private static var cachedRecords: [PackageRecord]?

    static func ownership(
        for app: InstalledApp,
        otherApps: [InstalledApp],
        isCancelled: (() -> Bool)? = nil
    ) -> Result {
        resolve(
            appPath: app.url.path,
            records: records(isCancelled: isCancelled),
            installedAppPaths: otherApps.map(\.url.path)
        )
    }

    static func prewarm() {
        _ = records()
    }

    /// Pure association step kept separate from receipt I/O so suite-package
    /// safety can be verified without reading the machine's package database.
    ///
    /// `installedAppPaths` is what separates a suite from a single product: only
    /// a bundle that is itself an installed application counts as a sibling. An
    /// app's own helper or updater `.app` is not one, so it stays removable
    /// instead of turning the whole package review-only and hiding itself.
    static func resolve(
        appPath: String,
        records: [PackageRecord],
        installedAppPaths: [String]
    ) -> Result {
        let selected = standardizedKey(appPath)
        let installed = Set(installedAppPaths.map(standardizedKey)).subtracting([selected])
        var files: [String: OwnedFile] = [:]
        var receiptIDs = Set<String>()
        var sharedIDs = Set<String>()

        for record in records where record.appPaths.contains(where: { standardizedKey($0) == selected }) {
            let others = Set(record.appPaths.map(standardizedKey)).subtracting([selected])
            // An empty inventory means the caller does not know what is installed,
            // not that nothing else is. Reading it as "no siblings" would call a
            // suite package exclusive and offer a live app for deletion, so fall
            // back to treating every other bundle in the receipt as a sibling.
            let siblings = installed.isEmpty ? others : others.intersection(installed)
            let isExclusive = siblings.isEmpty
            if isExclusive { receiptIDs.insert(record.id) } else { sharedIDs.insert(record.id) }

            for url in record.files {
                let path = url.standardizedFileURL.path
                let key = path.lowercased()
                if key == selected || siblings.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { continue }

                if let existing = files[key] {
                    files[key] = OwnedFile(
                        url: existing.url,
                        isExclusiveToApp: existing.isExclusiveToApp && isExclusive
                    )
                } else {
                    files[key] = OwnedFile(url: url, isExclusiveToApp: isExclusive)
                }
            }
        }

        // `ReceiptScanner.matchingIDs` also matches lexically, so a receipt whose
        // BOM never mentions this app (`com.parallels` vs `com.parallels.desktop`)
        // still gets listed. If it owns another installed app it must not arrive
        // pre-selected: a selected receipt row is `pkgutil --forget`.
        for record in records where !record.appPaths.contains(where: { standardizedKey($0) == selected }) {
            let others = Set(record.appPaths.map(standardizedKey)).subtracting([selected])
            if installed.isEmpty ? !others.isEmpty : !others.isDisjoint(with: installed) {
                sharedIDs.insert(record.id)
            }
        }

        return Result(
            files: files.values.sorted { $0.url.path < $1.url.path },
            removableReceiptIDs: receiptIDs.sorted(),
            sharedReceiptIDs: sharedIDs.subtracting(receiptIDs).sorted()
        )
    }

    /// Drop the index after uninstalling or forgetting a receipt.
    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedRecords = nil
    }

    // ponytail: one lock held across the whole build, so a scan starting during
    // the background prewarm waits for it rather than reading receipts twice.
    // Split into a state lock plus a build barrier only if that wait shows up.
    private static func records(isCancelled: (() -> Bool)? = nil) -> [PackageRecord] {
        lock.lock(); defer { lock.unlock() }
        if let cachedRecords { return cachedRecords }
        guard PackageScanner.isAvailable() else { return [] }

        let ids = PackageScanner.nonSystemPackageIDs().sorted()
        guard !ids.isEmpty else { return [] }

        var records = [PackageRecord?](repeating: nil, count: ids.count)
        records.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                guard isCancelled?() != true else { return }
                let rawFiles = PackageScanner.rawBOMFiles(id: ids[index], isCancelled: isCancelled)
                let appPaths = OrphanScanner.topLevelAppPaths(rawFiles).sorted()
                guard !appPaths.isEmpty else { return }
                buffer[index] = PackageRecord(
                    id: ids[index],
                    files: PackageBOMFilter.filter(rawFiles.map(\.path)).map { URL(fileURLWithPath: $0) },
                    appPaths: appPaths
                )
            }
        }

        let built = records.compactMap { $0 }
        // A cancelled build is missing packages; keeping it would later report
        // owned files as unowned.
        guard isCancelled?() != true else { return built }
        cachedRecords = built
        return built
    }

    private static func standardizedKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }
}
