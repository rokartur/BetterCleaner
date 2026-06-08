import Foundation

/// Which security domain a leftover file lives in. `system` files require admin
/// rights to trash; `user` files do not.
enum FileDomain {
    case user
    case system
}

/// One candidate file/folder surfaced by a scan. Reference type so a table cell
/// can flip `isSelected` in place without index bookkeeping.
final class FileItem {
    let url: URL
    /// Location category label (e.g. "Caches"), used to group rows.
    let category: String
    let domain: FileDomain
    let isDirectory: Bool
    var size: Int64
    var isSelected: Bool
    /// True when `size` is a lower bound because part of the tree couldn't be
    /// read (see `FileSize.sizeWithStatus`). The cell renders a "≈" prefix.
    var sizeIsApproximate: Bool
    /// When false, "Select All" skips this item — used to keep risky/uncertain
    /// rows (ask-first dev artifacts, low-confidence orphans, temp dirs, fonts)
    /// out of a blanket select. The user can still tick them individually.
    var isAutoSelectable: Bool
    /// Optional friendly label shown instead of the file name — e.g. a resolved
    /// simulator device name in place of its opaque UDID folder. Nil → file name.
    let title: String?

    init(
        url: URL,
        category: String,
        domain: FileDomain,
        isDirectory: Bool,
        size: Int64 = 0,
        isSelected: Bool = false,
        sizeIsApproximate: Bool = false,
        isAutoSelectable: Bool = true,
        title: String? = nil
    ) {
        self.url = url
        self.category = category
        self.domain = domain
        self.isDirectory = isDirectory
        self.size = size
        self.isSelected = isSelected
        self.sizeIsApproximate = sizeIsApproximate
        self.isAutoSelectable = isAutoSelectable
        self.title = title
    }

    var displayName: String { title ?? url.lastPathComponent }
    var path: String { url.path }
}
