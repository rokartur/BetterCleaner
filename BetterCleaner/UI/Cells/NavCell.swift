import AppKit

/// Native source-list row: a template SF Symbol, page title, and optional
/// reclaimable size. AppKit owns selection, vibrancy, focus, and contrast.
final class NavCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NavCell")

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateForegroundColors() }
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = Typography.body
        // The page name is what the user navigates by, so it outranks the size
        // badge for width — otherwise "System Junk" reads "System Ju… 20.07 GB".
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        sizeField.font = Typography.monospacedDigit(.caption1)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.lineBreakMode = .byTruncatingTail
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(sizeField)

        // AppKit still owns the source-list selection fill; these semantic
        // foregrounds keep custom subviews legible as cells are reused. Don't
        // register the custom field as NSTableCellView.textField: AppKit would
        // overwrite its semantic color after backgroundStyle changes.
        updateForegroundColors()

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: sizeField.leadingAnchor, constant: -Spacing.sm),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.sm),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateForegroundColors() {
        let selectedColor: NSColor? = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : nil
        titleField.textColor = selectedColor ?? .labelColor
        iconView.contentTintColor = selectedColor ?? .secondaryLabelColor
        sizeField.textColor = selectedColor ?? .secondaryLabelColor
    }

    /// `size` is the page's reclaimable bytes (nil/0 hides the label).
    func configure(symbol: String, title: String, size: Int64?) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        titleField.stringValue = title
        titleField.toolTip = title
        if let size, size > 0 {
            // Compact form: the badge slot is narrow, and the second decimal of
            // "20.07 GB" changes no decision — losing the unit to truncation does.
            let sizeText = FileSize.shortString(size)
            sizeField.stringValue = sizeText
            sizeField.isHidden = false
            setAccessibilityLabel("\(title), \(sizeText) reclaimable")
        } else {
            sizeField.stringValue = ""
            sizeField.isHidden = true
            setAccessibilityLabel(title)
        }
    }
}
