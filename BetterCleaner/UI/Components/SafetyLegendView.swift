import AppKit

/// A compact key explaining the per-row safety symbols: a green checkmark for
/// auto-selectable "safe" files and an amber warning triangle for review-only
/// ones. Shown above a results list so the inline symbols read without hovering
/// for the tooltip. Symbols + tints match `FileCell.applySafety` exactly.
@MainActor
final class SafetyLegendView: NSView {

    init() {
        super.init(frame: .zero)
        let safe = Self.item(symbol: "checkmark.circle.fill",
                             tint: .systemGreen,
                             text: "Safe to remove")
        let review = Self.item(symbol: "exclamationmark.triangle.fill",
                               tint: .systemOrange,
                               text: "Review before removing")

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
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// One legend entry: a tinted symbol next to a subdued caption.
    private static func item(symbol: String, tint: NSColor, text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = Typography.caption
        label.textColor = .secondaryLabelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.xs
        return row
    }
}
