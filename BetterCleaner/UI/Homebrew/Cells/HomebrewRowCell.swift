import AppKit

/// One inline pill spec. `color == nil` renders a subtle gray tag ("dep", a source
/// domain); a non-nil color renders a filled colored pill ("brew", "GitHub",
/// "Running", "Official").
struct PillSpec {
    let text: String
    let color: NSColor?
}

/// A row model for the Homebrew master list, styled after TapHouse: a leading icon
/// tile, a bold name with an optional orange "update" badge and inline pills, a
/// description line, and a trailing version.
struct HomebrewRowModel {
    enum Leading {
        case glyph(symbol: String, color: NSColor)
        case appIcon(NSImage)
    }
    let leading: Leading
    let title: String
    var pills: [PillSpec] = []
    var subtitle: String = ""
    var version: String = ""
    var updateAvailable: Bool = false
}

/// Row cell for the Homebrew master list. One cell serves every category
/// (packages / services / taps) and the auxiliary sheets.
final class HomebrewRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HomebrewRow")

    private let tile = IconTileView(size: 40, corner: 9)
    private let titleField = NSTextField(labelWithString: "")
    private let updateBadge = NSImageView()
    private let pillsRow = NSStackView()
    private let subtitleField = NSTextField(labelWithString: "")
    private let versionField = NSTextField(labelWithString: "")
    private let separator = NSBox()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.font = Typography.semibold(.title3)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        updateBadge.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Update available")
        updateBadge.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        updateBadge.contentTintColor = .systemOrange
        updateBadge.toolTip = "Update available"
        updateBadge.setContentHuggingPriority(.required, for: .horizontal)
        updateBadge.isHidden = true

        pillsRow.orientation = .horizontal
        pillsRow.alignment = .centerY
        pillsRow.spacing = 5
        pillsRow.setContentHuggingPriority(.required, for: .horizontal)
        pillsRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleField.font = Typography.subheadline
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail

        versionField.font = Typography.monospacedDigit(.subheadline)
        versionField.textColor = .secondaryLabelColor
        versionField.alignment = .right
        versionField.lineBreakMode = .byTruncatingTail
        versionField.setContentHuggingPriority(.required, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleField, updateBadge, pillsRow, titleSpacer])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let textStack = NSStackView(views: [titleRow, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [tile, textStack, versionField, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Spacing.md),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: versionField.leadingAnchor, constant: -Spacing.sm),
            titleRow.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),

            versionField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            versionField.centerYAnchor.constraint(equalTo: centerYAnchor),
            versionField.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            separator.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.lg),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// White text on the blue selection capsule; normal colors otherwise.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            titleField.textColor = emphasized ? .white : .labelColor
            subtitleField.textColor = emphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            versionField.textColor = emphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            separator.isHidden = emphasized
        }
    }

    func configure(_ m: HomebrewRowModel) {
        switch m.leading {
        case .glyph(let symbol, let color): tile.setGlyph(symbol, color: color)
        case .appIcon(let image):           tile.setAppIcon(image)
        }
        titleField.stringValue = m.title
        updateBadge.isHidden = !m.updateAvailable

        pillsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for pill in m.pills {
            if let color = pill.color {
                let p = StatusPill()
                p.set(text: pill.text, color: color)
                pillsRow.addArrangedSubview(p)
            } else {
                pillsRow.addArrangedSubview(TagPill(pill.text))
            }
        }

        subtitleField.stringValue = m.subtitle
        subtitleField.isHidden = m.subtitle.isEmpty
        versionField.stringValue = m.version
        versionField.isHidden = m.version.isEmpty
    }

    /// Back-compat path for the search / adopt sheets, which pass a plain image
    /// and an optional colored badge.
    func configure(icon: NSImage?, title: String, subtitle: String, badgeText: String?, badgeColor: NSColor) {
        let leading: HomebrewRowModel.Leading = icon.map { .appIcon($0) } ?? .glyph(symbol: "shippingbox", color: .systemGray)
        var pills: [PillSpec] = []
        if let badgeText, !badgeText.isEmpty { pills.append(PillSpec(text: badgeText, color: badgeColor)) }
        configure(HomebrewRowModel(leading: leading, title: title, pills: pills, subtitle: subtitle))
    }
}

/// Table row view that paints the selection as a rounded accent capsule (TapHouse
/// style) instead of the system bar, and stays vivid even when the table isn't the
/// first responder.
final class HomebrewRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.setFill()
        path.fill()
    }
}

/// Group-header row ("Casks 16" / "Formulae 227") for the grouped Installed list.
final class HomebrewHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HomebrewHeader")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = Typography.semibold(.headline)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.md),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ text: String) { label.stringValue = text }
}
