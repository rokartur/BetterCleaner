import CoreGraphics

/// Shared sizing tokens: a small set of row heights (replacing the old mix of
/// 26/32/44/46), corner radii for glass surfaces and badges, and the window
/// minimum. Migrated from the per-file `Metrics` enums that used to live inside
/// individual view controllers.
enum Metrics {
    /// Standard content list row (files, packages, apps).
    static let rowHeight: CGFloat = 44
    /// Compact row — sidebar sections, collapsed group rows.
    static let compactRowHeight: CGFloat = 32
    /// Section-header row inside a content list.
    static let headerRowHeight: CGFloat = 28

    /// Corner radius for large glass surfaces (cards, floating action bars).
    static let glassCornerRadius: CGFloat = 16
    /// Corner radius for medium controls (search, popovers).
    static let controlCornerRadius: CGFloat = 10
    /// Corner radius for small icon badges.
    static let badgeCornerRadius: CGFloat = 6

    /// Sidebar / list icon-badge sizing.
    static let badgeSize: CGFloat = 20
    static let badgeIconSize: CGFloat = 15

    /// File/app row icon size.
    static let listIconSize: CGFloat = 24

    static let minWindow = CGSize(width: 880, height: 500)
}
