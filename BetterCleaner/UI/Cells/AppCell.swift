import AppKit

/// Row cell for the installed-apps list: icon + name. Row height matches the
/// main navigation sidebar (32pt).
final class AppCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("AppCell")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.translatesAutoresizingMaskIntoConstraints = false

        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = Typography.body

        // Trailing size column — mirrors FileCell so the user can see which app is
        // biggest at a glance. Monospaced digits keep the column from jiggling.
        sizeField.font = Typography.monospacedDigit(.subheadline)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(nameField)
        addSubview(sizeField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.listIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.listIconSize),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: sizeField.leadingAnchor, constant: -Spacing.sm),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `size` is the app bundle size (nil until computed off-thread). Nil/0 hides
    /// the label so a not-yet-measured row never reads "Zero KB".
    func configure(app: InstalledApp, size: Int64?) {
        iconView.image = IconCache.icon(forPath: app.url.path)
        nameField.stringValue = app.name
        if let size, size > 0 {
            sizeField.stringValue = FileSize.string(size)
            sizeField.isHidden = false
        } else {
            sizeField.stringValue = ""
            sizeField.isHidden = true
        }
    }
}
