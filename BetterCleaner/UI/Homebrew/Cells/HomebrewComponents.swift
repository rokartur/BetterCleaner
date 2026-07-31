import AppKit

/// Shared visual building blocks for the Homebrew screens: key-value info rows and
/// a flipped container for top-anchored scroll content. Native +
/// appearance-adaptive (no hardcoded palette).
///
/// Inline status/tag chips live in the app-wide `StatusChip`; leading row icons are
/// plain template symbols configured by the cell that owns them. Neither needs a
/// Homebrew-specific variant.

/// A flipped view so scroll-view content lays out from the top down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A stacked key/value cell: a small gray caption over its value (TapHouse's
/// "Information" grid style). The value can be a plain string or a clickable link.
final class KeyValueView: NSView {
    private var onClick: (() -> Void)?

    init(key: String, value: String, link: Bool = false, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = Typography.caption
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail

        let valueView: NSView
        if link {
            let button = NSButton(title: value, target: self, action: #selector(linkTapped))
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .linkColor
            button.alignment = .left
            button.font = Typography.subheadline
            button.setButtonType(.momentaryChange)
            valueView = button
        } else {
            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = Typography.subheadline
            valueLabel.textColor = .labelColor
            valueLabel.isSelectable = true
            valueView = valueLabel
        }
        valueView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [keyLabel, valueView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func linkTapped() { onClick?() }
}
