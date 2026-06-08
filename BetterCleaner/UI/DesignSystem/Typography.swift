import AppKit

/// App typography built on the system's Dynamic-Type text styles
/// (`NSFont.preferredFont(forTextStyle:)`) instead of hardcoded point sizes, so
/// text scales with the user's setting and stays visually consistent. Use these
/// in place of `.systemFont(ofSize:)`.
enum Typography {
    static var largeTitle: NSFont { .preferredFont(forTextStyle: .largeTitle) }
    static var title: NSFont { .preferredFont(forTextStyle: .title2) }
    static var title3: NSFont { .preferredFont(forTextStyle: .title3) }
    /// Bold-ish heading used for page titles and card titles.
    static var headline: NSFont { .preferredFont(forTextStyle: .headline) }
    static var body: NSFont { .preferredFont(forTextStyle: .body) }
    static var callout: NSFont { .preferredFont(forTextStyle: .callout) }
    static var subheadline: NSFont { .preferredFont(forTextStyle: .subheadline) }
    static var footnote: NSFont { .preferredFont(forTextStyle: .footnote) }
    static var caption: NSFont { .preferredFont(forTextStyle: .caption1) }

    /// A semibold variant of a text style, for emphasis where the plain style is
    /// too light (e.g. section headers, selected titles).
    static func semibold(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return .systemFont(ofSize: base.pointSize, weight: .semibold)
    }

    /// A medium-weight variant of a text style, for light emphasis (e.g. group
    /// cluster titles) that shouldn't read as heavy as semibold.
    static func medium(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return .systemFont(ofSize: base.pointSize, weight: .medium)
    }

    /// Tabular-figure variant of a text style for size columns / percentages that
    /// must not jiggle horizontally as digits change.
    static func monospacedDigit(_ style: NSFont.TextStyle = .subheadline, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return .monospacedDigitSystemFont(ofSize: base.pointSize, weight: weight)
    }
}
