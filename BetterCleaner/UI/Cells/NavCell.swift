import AppKit
import QuartzCore

/// Row cell for the navigation sidebar, rendered 1:1 with the BetterSettings tab
/// cell: a white SF Symbol on a rounded colored gradient badge (`NavIconBadge`),
/// the page title, and an optional trailing reclaimable size. Content sits inside
/// the 9pt selection capsule (`NavRowView`); the title + size invert to white on
/// the emphasized (key-window) accent capsule, while the colored badge keeps its
/// tint (System Settings behavior).
final class NavCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NavCell")

    private let iconBadge = NavIconBadge()
    private let titleField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.translatesAutoresizingMaskIntoConstraints = false

        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = Typography.body

        sizeField.font = Typography.monospacedDigit(.subheadline)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconBadge)
        addSubview(titleField)
        addSubview(sizeField)

        // The title is the designated outlet so NSTableCellView auto-inverts it to
        // white on the emphasized capsule.
        textField = titleField

        // Inset content past the capsule edge: capsule (9pt) + inner padding (6pt).
        let contentInset = Metrics.sidebarRowPadding + Metrics.sidebarContentPadding
        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            iconBadge.heightAnchor.constraint(equalToConstant: Metrics.badgeSize),

            titleField.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: Metrics.sidebarContentPadding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: sizeField.leadingAnchor, constant: -Spacing.sm),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `size` is the page's reclaimable bytes (nil/0 hides the label).
    func configure(symbol: String, title: String, size: Int64?, color: NSColor) {
        iconBadge.configure(symbol: symbol, color: color)
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
            // The trailing size isn't auto-managed the way the designated `textField`
            // is: white on the emphasized accent capsule, secondary otherwise. The
            // colored badge keeps its tint regardless, so it isn't touched here.
            sizeField.textColor = (backgroundStyle == .emphasized) ? .white : .secondaryLabelColor
        }
    }
}

/// The rounded colored icon badge: a white SF Symbol over a subtle vertical
/// gradient tile with a hairline border + soft shadow. A self-contained port of
/// BetterSettings' `SidebarIconBadgeView` (its sidebar component is internal, so
/// it can't be imported standalone).
final class NavIconBadge: NSView {
    override var allowsVibrancy: Bool { false }

    private let gradientLayer = CAGradientLayer()
    private let symbolView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.badgeCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.shadowOpacity = 0.30
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.cornerRadius = Metrics.badgeCornerRadius
        gradientLayer.cornerCurve = .continuous
        gradientLayer.masksToBounds = true
        layer?.addSublayer(gradientLayer)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .white
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Metrics.badgeCornerRadius, cornerHeight: Metrics.badgeCornerRadius, transform: nil)
    }

    func configure(symbol: String, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: Metrics.badgeIconSize - 2, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        image?.isTemplate = true
        symbolView.image = image
        // Lighten the top edge for the System Settings tile sheen.
        let top = color.blended(withFraction: 0.18, of: .white) ?? color
        gradientLayer.colors = [top.cgColor, color.cgColor]
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
    }
}
