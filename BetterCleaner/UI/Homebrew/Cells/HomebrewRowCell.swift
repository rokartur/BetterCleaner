import AppKit

/// Row cell for the Homebrew master list: a leading icon, a title over a secondary
/// subtitle, and an optional trailing status pill ("Update", "Running", "Official").
/// One cell serves all three categories (packages / services / taps).
final class HomebrewRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HomebrewRow")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let badge = PillView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for v in [iconView, titleField, subtitleField, badge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleField.font = Typography.body
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = Typography.footnote
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail

        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.listIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.listIconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Spacing.sm),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Spacing.sm),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(icon: NSImage?, title: String, subtitle: String, badgeText: String?, badgeColor: NSColor) {
        iconView.image = icon
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        badge.set(text: badgeText, color: badgeColor)
    }
}

/// A small rounded status pill (white text on a tinted capsule). Hidden when its
/// text is nil/empty so badge-less rows render with no trailing gap.
final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.semibold(.caption1)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(text: String?, color: NSColor) {
        guard let text, !text.isEmpty else { isHidden = true; return }
        isHidden = false
        label.stringValue = text
        layer?.backgroundColor = color.cgColor
    }
}
