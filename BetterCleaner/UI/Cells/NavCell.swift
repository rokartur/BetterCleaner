import AppKit

/// Row cell for the navigation sidebar: a monochrome (template) SF Symbol, the
/// page title, and an optional trailing reclaimable size. Because the symbol is a
/// template image and the title is the cell's designated `textField`, both
/// auto-invert to white when the row is selected (emphasized); the trailing size
/// follows via `backgroundStyle`.
final class NavCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NavCell")

    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.translatesAutoresizingMaskIntoConstraints = false

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .secondaryLabelColor

        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = Typography.body

        sizeField.font = Typography.monospacedDigit(.subheadline)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(symbolView)
        addSubview(titleField)
        addSubview(sizeField)

        // Wire the standard outlets so NSTableCellView auto-tints them on selection.
        imageView = symbolView
        textField = titleField

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 16pt glyph centered in a 20pt container, matching BetterSettings.
            symbolView.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            symbolView.heightAnchor.constraint(equalToConstant: Metrics.badgeSize),

            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: Spacing.sm),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: sizeField.leadingAnchor, constant: -Spacing.sm),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `size` is the page's reclaimable bytes (nil/0 hides the label).
    func configure(symbol: String, title: String, size: Int64?) {
        let cfg = NSImage.SymbolConfiguration(pointSize: Metrics.badgeIconSize, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        image?.isTemplate = true
        symbolView.image = image
        titleField.stringValue = title
        if let size, size > 0 {
            sizeField.stringValue = FileSize.string(size)
            sizeField.isHidden = false
        } else {
            sizeField.stringValue = ""
            sizeField.isHidden = true
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // The symbol and the trailing size aren't auto-managed the way the
            // designated `textField` is, so tint them by hand: white on the
            // selected (emphasized) row, secondary otherwise.
            let emphasized = (backgroundStyle == .emphasized)
            symbolView.contentTintColor = emphasized ? .white : .secondaryLabelColor
            sizeField.textColor = emphasized ? .white : .secondaryLabelColor
        }
    }
}
