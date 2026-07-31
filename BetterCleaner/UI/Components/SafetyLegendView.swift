import AppKit

/// A compact key explaining the per-row safety symbols: a green checkmark for
/// auto-selectable "safe" files and an amber warning triangle for review-only
/// ones. Shown above a results list so the inline symbols read without hovering
/// for the tooltip. Symbols + tints match `FileCell.applySafety` exactly.
///
/// `setCounts(safe:review:)` turns the static key into a live breakdown — "96
/// safe to remove", "32 need review" — so the row above the list answers *how
/// much of this is the easy decision* instead of only restating the symbols.
@MainActor
final class SafetyLegendView: NSView {
    private let safeLabel = NSTextField(labelWithString: "")
    private let reviewLabel = NSTextField(labelWithString: "")
    private let reviewEntry: NSView

    init() {
        let safe = Self.item(symbol: "checkmark.circle.fill",
                             tint: .systemGreen,
                             label: safeLabel,
                             text: "Safe to remove")
        let review = Self.item(symbol: "exclamationmark.triangle.fill",
                               tint: .systemOrange,
                               label: reviewLabel,
                               text: "Review before removing")
        reviewEntry = review
        super.init(frame: .zero)

        let stack = NSStackView(views: [safe, review])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show how the results split between the two confidence levels. A run with
    /// nothing to review drops that entry entirely rather than printing "0".
    func setCounts(safe: Int, review: Int) {
        safeLabel.stringValue = "\(safe) safe to remove"
        reviewLabel.stringValue = "\(review) need\(review == 1 ? "s" : "") review"
        reviewEntry.isHidden = review == 0
        setAccessibilityLabel(
            reviewEntry.isHidden
                ? "\(safe) items safe to remove"
                : "\(safe) items safe to remove, \(review) need review"
        )
    }

    /// One legend entry: a tinted symbol next to a subdued caption.
    private static func item(symbol: String, tint: NSColor, label: NSTextField, text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = tint
        icon.setAccessibilityElement(false)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.stringValue = text
        // Tabular digits so the counts don't shift the caption as they change.
        label.font = Typography.monospacedDigit(.caption1)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.xs
        return row
    }
}
