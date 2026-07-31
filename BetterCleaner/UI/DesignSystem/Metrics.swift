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
    /// Sidebar group-header left inset.
    static let sidebarHeaderInset: CGFloat = 16
    /// Gap from the traffic-light close button's bottom to the first sidebar content
    /// (BetterSettings `searchOffsetBelowTrafficLights`).
    static let sidebarTrafficLightOffset: CGFloat = 26

    /// Corner radius for large glass surfaces (cards, floating action bars).
    static let glassCornerRadius: CGFloat = 16
    /// Corner radius for medium controls (search, popovers).
    static let controlCornerRadius: CGFloat = 10
    /// Corner radius for inline status/tag chips (`StatusChip`).
    static let chipCornerRadius: CGFloat = 5
    /// Sidebar / list icon sizing.
    static let badgeSize: CGFloat = 20

    /// File/app row icon size.
    static let listIconSize: CGFloat = 24
    /// Fixed width of the trailing size column in results lists. Fixed rather than
    /// intrinsic so the safety dots to its left form a straight column instead of
    /// stepping in and out as "12.21 GB" and "86.5 MB" alternate down the list.
    static let sizeColumnWidth: CGFloat = 88
    /// Slot reserved for the "needs admin rights" lock badge. Always reserved, even
    /// on rows without a lock, so the safety-dot column doesn't jump a row when a
    /// system-domain file appears among user-domain ones.
    static let lockSlotWidth: CGFloat = 14
    /// Trailing inset of the safety-dot column, shared by file, group and section
    /// rows so all three land on one vertical line.
    static var safetyDotInset: CGFloat {
        Spacing.md + sizeColumnWidth + Spacing.sm + lockSlotWidth + Spacing.sm
    }

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
    /// Initial widths for the navigation and master-list columns.
    static let sidebarDefaultWidth: CGFloat = 228
    static let listColumnDefaultWidth: CGFloat = 320

    static let defaultWindow = CGSize(width: 1040, height: 660)
    static let minWindow = CGSize(width: 880, height: 500)
}
