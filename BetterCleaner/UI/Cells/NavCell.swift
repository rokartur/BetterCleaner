import AppKit

/// Row cell for the navigation sidebar, laid out 1:1 with the BetterSettings tab
/// cell: a system-accent SF Symbol (16pt glyph in a 20pt slot), the page title,
/// and an optional trailing reclaimable size. Content is inset to sit inside the
/// 9pt selection capsule (`NavRowView`). On the emphasized (key-window) selection
/// the accent capsule fills the row, so the glyph + text invert to white.
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
        // Accent-tinted glyphs (Finder / System Settings sidebar look).
        symbolView.contentTintColor = .controlAccentColor

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

        // Wire the standard outlets so NSTableCellView auto-tints the title on
        // selection (the glyph + size follow via `backgroundStyle`).
        imageView = symbolView
        textField = titleField

        // Inset content past the capsule edge: capsule (9pt) + inner padding (6pt).
        let contentInset = Metrics.sidebarRowPadding + Metrics.sidebarContentPadding
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 16pt glyph centered in a 20pt container, matching BetterSettings.
            symbolView.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            symbolView.heightAnchor.constraint(equalToConstant: Metrics.badgeSize),

            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: Metrics.sidebarContentPadding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: sizeField.leadingAnchor, constant: -Spacing.sm),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset),
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
            // The glyph + trailing size aren't auto-managed the way the designated
            // `textField` is: white on the emphasized (accent capsule) row, else the
            // glyph stays accent-tinted and the size secondary.
            let emphasized = (backgroundStyle == .emphasized)
            symbolView.contentTintColor = emphasized ? .white : .controlAccentColor
            sizeField.textColor = emphasized ? .white : .secondaryLabelColor
        }
    }
}
