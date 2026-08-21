import Foundation

/// A macOS installer-package receipt belonging to an app. Receipts persist in
/// `/var/db/receipts` (and the `pkgutil` database) after the app is gone; a
/// complete uninstall forgets them so the system no longer believes the package
/// is installed.
struct AppReceipt {
    let id: String
    let version: String
    let bomPath: URL?
    let plistPath: URL?
}

/// Finds the package receipts that belong to a specific app and exposes them as
/// scan results. Listing uses `pkgutil` (no admin); forgetting (in `AppRemover`)
/// uses `pkgutil --forget` via the privileged path.
enum ReceiptScanner {
    private static let receiptsDir = "/var/db/receipts"
    private static let pkgutil = "/usr/sbin/pkgutil"

    /// Receipt ids that belong to `descriptor`: equal to, a child of, or a parent
    /// of one of the app's bundle ids. Pure (no `Process`); unit-tested.
    static func matchingIDs(_ allIDs: [String], descriptor: AppDescriptor) -> [String] {
        let bids = descriptor.allBundleIDs
        guard !bids.isEmpty else { return [] }
        return allIDs.filter { id in
            let lower = id.lowercased()
            return bids.contains { bid in
                !bid.isEmpty && (lower == bid || lower.hasPrefix(bid + ".") || bid.hasPrefix(lower + "."))
            }
        }
    }

    /// All installed receipt ids, preferring `pkgutil` and falling back to a
    /// direct `/var/db/receipts` listing if it's unavailable.
    private static func allReceiptIDs() -> [String] {
        if FileManager.default.isExecutableFile(atPath: pkgutil) {
            let list = CommandRunner.run(pkgutil, ["--pkgs"])
            if list.ok { return PackageScanner.parsePackageList(list.stdout) }
        }
        return directReceiptIDs()
    }

    /// The receipts owned by `descriptor`. Includes each receipt's `version`,
    /// which costs one `pkgutil --pkg-info` spawn per id — use `fileItems(for:)`
    /// (which doesn't need versions) on the scan hot path.
    static func receipts(for descriptor: AppDescriptor) -> [AppReceipt] {
        let hasPkgutil = FileManager.default.isExecutableFile(atPath: pkgutil)
        let matched = matchingIDs(allReceiptIDs(), descriptor: descriptor)
        return matched.map { id in
            let version = hasPkgutil
                ? PackageScanner.parsePkgInfo(CommandRunner.run(pkgutil, ["--pkg-info", id]).stdout).version
                : ""
            return AppReceipt(id: id, version: version, bomPath: existing("\(receiptsDir)/\(id).bom"), plistPath: existing("\(receiptsDir)/\(id).plist"))
        }
    }

    /// Receipts as `FileItem`s for the per-app scan, one row per id under the
    /// "Receipts" category. The url's stem is the pkg id, so `AppRemover` can
    /// `pkgutil --forget` it rather than trashing the loose files. Builds from the
    /// receipt filenames only — no per-id `pkgutil --pkg-info` spawn (version is
    /// unused here), so this stays O(1) processes regardless of match count.
    ///
    /// `sharedIDs` are receipts a bundle-id prefix match would otherwise select
    /// even though they also own a sibling application. They are still listed —
    /// forgetting one is a user decision — but never pre-selected, because
    /// `AppRemover` turns a selected row straight into `pkgutil --forget`.
    static func fileItems(
        for descriptor: AppDescriptor,
        additionalIDs: [String] = [],
        sharedIDs: [String] = []
    ) -> [FileItem] {
        let shared = Set(sharedIDs)
        let ids = Set(matchingIDs(allReceiptIDs(), descriptor: descriptor))
            .union(additionalIDs)
            .sorted()
        return ids.map { id in
            let plist = existing("\(receiptsDir)/\(id).plist")
            let bom = existing("\(receiptsDir)/\(id).bom")
            let url = plist ?? bom ?? URL(fileURLWithPath: "\(receiptsDir)/\(id).plist")
            let size = [plist, bom].compactMap { $0 }.reduce(Int64(0)) { $0 + FileSize.size(of: $1) }
            let isShared = shared.contains(id)
            return FileItem(
                url: url,
                category: "Receipts",
                domain: .system,
                isDirectory: false,
                size: size,
                isSelected: !isShared,
                isAutoSelectable: !isShared
            )
        }
    }

    /// The pkg id a "Receipts" `FileItem` represents (its filename without the
    /// `.plist`/`.bom` extension).
    static func receiptID(for item: FileItem) -> String {
        item.url.deletingPathExtension().lastPathComponent
    }

    private static func directReceiptIDs() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: receiptsDir) else { return [] }
        var ids = Set<String>()
        for name in entries where name.hasSuffix(".plist") || name.hasSuffix(".bom") {
            ids.insert((name as NSString).deletingPathExtension)
        }
        return Array(ids)
    }

    private static func existing(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
