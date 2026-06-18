import AppKit

/// A row model for the Homebrew master list, styled after TapHouse: a leading icon
/// tile, a bold name with inline tag/status pills, a description line, and a trailing
/// version (with a green "→ new" when an update is available).
struct HomebrewRowModel {
    enum Leading {
        case glyph(symbol: String, color: NSColor)
        case appIcon(NSImage)
    }
    let leading: Leading
    let title: String
    var tags: [String] = []
    var status: (text: String, color: NSColor)? = nil
    var subtitle: String = ""
    /// Trailing version text; when `newVersion` is set it renders "old → new" (new in green).
    var version: String = ""
    var newVersion: String? = nil
}

/// Row cell for the Homebrew master list. One cell serves every category
/// (packages / services / taps) and both the main list and the auxiliary sheets.
final class HomebrewRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HomebrewRow")

    private let tile = IconTileView(size: 30)
    private let titleField = NSTextField(labelWithString: "")
    private let tagsRow = NSStackView()
    private let subtitleField = NSTextField(labelWithString: "")
    private let versionField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.font = Typography.semibold(.body)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tagsRow.orientation = .horizontal
        tagsRow.alignment = .centerY
        tagsRow.spacing = 4
        tagsRow.setContentHuggingPriority(.required, for: .horizontal)
        tagsRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleField.font = Typography.footnote
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail

        versionField.font = Typography.monospacedDigit(.caption1)
        versionField.textColor = .secondaryLabelColor
        versionField.alignment = .right
        versionField.lineBreakMode = .byTruncatingTail
        versionField.setContentHuggingPriority(.required, for: .horizontal)
        versionField.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title line: name then its tag/status pills, left-aligned (trailing spacer).
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleField, tagsRow, titleSpacer])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let textStack = NSStackView(views: [titleRow, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [tile, textStack, versionField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Spacing.sm),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: versionField.leadingAnchor, constant: -Spacing.sm),
            titleRow.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),

            versionField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            versionField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ m: HomebrewRowModel) {
        switch m.leading {
        case .glyph(let symbol, let color): tile.setGlyph(symbol, color: color)
        case .appIcon(let image):           tile.setAppIcon(image)
        }
        titleField.stringValue = m.title

        // Rebuild the inline pills (cells are reused).
        tagsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in m.tags { tagsRow.addArrangedSubview(TagPill(tag)) }
        if let status = m.status {
            let pill = StatusPill()
            pill.set(text: status.text, color: status.color)
            tagsRow.addArrangedSubview(pill)
        }

        subtitleField.stringValue = m.subtitle
        subtitleField.isHidden = m.subtitle.isEmpty

        if let newVersion = m.newVersion, !newVersion.isEmpty {
            let s = NSMutableAttributedString(
                string: m.version,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Typography.monospacedDigit(.caption1)])
            s.append(NSAttributedString(
                string: "  →  \(newVersion)",
                attributes: [.foregroundColor: NSColor.systemGreen, .font: Typography.monospacedDigit(.caption1, weight: .semibold)]))
            versionField.attributedStringValue = s
        } else {
            versionField.stringValue = m.version
        }
        versionField.isHidden = m.version.isEmpty && m.newVersion == nil
    }

    /// Back-compat path for the search / adopt / CVE sheets, which pass a plain image
    /// and an optional colored badge.
    func configure(icon: NSImage?, title: String, subtitle: String, badgeText: String?, badgeColor: NSColor) {
        let leading: HomebrewRowModel.Leading = icon.map { .appIcon($0) } ?? .glyph(symbol: "shippingbox", color: .systemGray)
        var status: (String, NSColor)? = nil
        if let badgeText, !badgeText.isEmpty { status = (badgeText, badgeColor) }
        configure(HomebrewRowModel(leading: leading, title: title, status: status, subtitle: subtitle))
    }
}
