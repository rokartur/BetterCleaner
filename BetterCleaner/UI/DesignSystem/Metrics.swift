import CoreGraphics

/// Shared sizing tokens: a small set of row heights (replacing the old mix of
/// 26/32/44/46), corner radii for glass surfaces and badges, and the window
/// minimum. Migrated from the per-file `Metrics` enums that used to live inside
/// individual view controllers.
enum Metrics {
    /// Standard content list row (files, packages, apps).
    static let rowHeight: CGFloat = 44
    /// Compact row — sidebar rows, app/package list rows, collapsed group rows.
    /// 32pt matches the BetterSettings tab list (its source-list `tabHeight`).
    static let compactRowHeight: CGFloat = 32
    /// Section-header row inside a content list (compact uppercase caption header).
    static let headerRowHeight: CGFloat = 28
    /// Sidebar footer control (Settings) — restrained, like the BetterSettings footer.
    static let sidebarFooterHeight: CGFloat = 28

    /// Corner radius for large glass surfaces (cards, floating action bars).
    static let glassCornerRadius: CGFloat = 16
    /// Corner radius for medium controls (search, popovers).
    static let controlCornerRadius: CGFloat = 10
    /// Corner radius for small icon badges.
    static let badgeCornerRadius: CGFloat = 6

    /// Sidebar / list icon-badge sizing. 16pt matches the native sidebar glyph.
    static let badgeSize: CGFloat = 20
    static let badgeIconSize: CGFloat = 16

    /// File/app row icon size.
    static let listIconSize: CGFloat = 24

    /// Centered "nothing here" glyph + its prose wrap width.
    static let emptyStateIconSize: CGFloat = 38
    static let emptyStateMaxWidth: CGFloat = 320
    /// Drag-and-drop overlay glyph.
    static let dragDropIconSize: CGFloat = 44
    /// Compact path rows (Exclusions settings list).
    static let pathRowHeight: CGFloat = 26
    /// Delete History master/detail rows (two-line cells, slightly taller).
    static let historyFileRowHeight: CGFloat = 48
    static let historyBatchRowHeight: CGFloat = 56
    /// Fixed master-column width in master/detail panes.
    static let masterDetailWidth: CGFloat = 320

    static let minWindow = CGSize(width: 880, height: 500)
}
