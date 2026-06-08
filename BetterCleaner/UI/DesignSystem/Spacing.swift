import CoreGraphics

/// Centralized spacing scale (points). Replaces the ad-hoc 4/6/8/10/12/16
/// literals that were scattered across every view controller so padding and
/// gaps stay consistent across the whole UI. Prefer these over raw numbers.
enum Spacing {
    /// 4 — hairline gaps inside a stacked label pair.
    static let xs: CGFloat = 4
    /// 8 — tight gap between related controls.
    static let sm: CGFloat = 8
    /// 12 — default gap between stack items / inner padding.
    static let md: CGFloat = 12
    /// 16 — standard content margin (leading/trailing/edges).
    static let lg: CGFloat = 16
    /// 24 — generous section separation / card padding.
    static let xl: CGFloat = 24
    /// 32 — hero / empty-state breathing room.
    static let xxl: CGFloat = 32
}
