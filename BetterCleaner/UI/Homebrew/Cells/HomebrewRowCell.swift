import AppKit

/// One inline chip spec. `color == nil` renders the neutral taxonomy chip ("dep",
/// "Formula"); a non-nil color renders a state chip ("Running", "Official").
///
/// State chips must carry a `symbol` — the tint alone can't survive grayscale,
/// Increased Contrast, or colour-blind vision. Taxonomy chips carry none.
struct PillSpec {
    let text: String
    let color: NSColor?
    var symbol: String?

    init(text: String, color: NSColor?, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }
}

/// A row model for the Homebrew master list, styled after TapHouse: a leading icon
/// tile, a bold name with an optional orange "update" badge and inline pills, a
/// description line, and a trailing version.
struct HomebrewRowModel {
    enum Leading {
        /// A plain template SF Symbol. No tint argument: a decorative colour on the
        /// row icon duplicates what the row's state chip already says.
        case glyph(symbol: String)
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

    private let tile = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let updateBadge = NSImageView()
    private let pillsRow = NSStackView()
    private let subtitleField = NSTextField(labelWithString: "")
    private let versionField = NSTextField(labelWithString: "")
    private let separator = NSBox()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        tile.imageScaling = .scaleProportionallyUpOrDown
        tile.wantsLayer = true
        tile.layer?.cornerCurve = .continuous
        tile.layer?.masksToBounds = true
        tile.setAccessibilityElement(false)
        tile.setContentHuggingPriority(.required, for: .horizontal)

        // Body weight, like every other list row in the app. A title3 semibold
        // name turned this list into a page of headings instead of a dense list.
        titleField.font = Typography.body
        titleField.lineBreakMode = .byTruncatingTail
        // The name gives way before the version does. A name clipped to "Microsoft
        // Visual Studio…" is still recognisable; a version clipped to "1.1…" is
        // noise. Still well above the description, which yields first.
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
        // Pills are annotations, so they yield before the name does.
        pillsRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleField.font = Typography.caption
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        versionField.font = Typography.monospacedDigit(.caption1)
        versionField.textColor = .secondaryLabelColor
        versionField.alignment = .right
        versionField.lineBreakMode = .byTruncatingTail
        versionField.setContentHuggingPriority(.required, for: .horizontal)
        // Never truncated: it's short, and a partial version answers nothing.
        versionField.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        for child in [tile, textStack, versionField] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Metrics.listIconSize),
            tile.heightAnchor.constraint(equalToConstant: Metrics.listIconSize),

            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Spacing.md),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: versionField.leadingAnchor, constant: -Spacing.sm),
            titleRow.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),

            versionField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            versionField.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A version is an annotation, not the row's subject. Capped so a long
            // one can't take half the column away from the name and description.
            versionField.widthAnchor.constraint(lessThanOrEqualToConstant: 96),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Follow the row's background: AppKit sets `.emphasized` on the native inset
    /// selection, and the system selected-text colors keep contrast correct in
    /// light, dark, Increased Contrast, and when the window loses focus.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            // No alpha on the selected-text colour: fading a semantic colour is
            // exactly what Increased Contrast asks the system not to do. AppKit's
            // two selected-text colours already encode the primary/secondary pair.
            titleField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            let secondary: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            subtitleField.textColor = secondary
            versionField.textColor = secondary
        }
    }

    func configure(_ model: HomebrewRowModel) {
        switch model.leading {
        case .glyph(let symbol):
            let config = NSImage.SymbolConfiguration(pointSize: Metrics.listIconSize * 0.68, weight: .regular)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            tile.image = image
            tile.contentTintColor = .secondaryLabelColor
            tile.layer?.cornerRadius = 0
        case .appIcon(let image):
            image.isTemplate = false
            tile.image = image
            tile.contentTintColor = nil
            tile.layer?.cornerRadius = 5
        }
        titleField.stringValue = model.title
        updateBadge.isHidden = !model.updateAvailable

        pillsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for pill in model.pills {
            let chip = StatusChip()
            chip.configure(text: pill.text, symbol: pill.symbol, tint: pill.color)
            pillsRow.addArrangedSubview(chip)
        }

        subtitleField.stringValue = model.subtitle
        subtitleField.isHidden = model.subtitle.isEmpty
        versionField.stringValue = Self.shortVersion(model.version)
        versionField.isHidden = model.version.isEmpty
        // The untrimmed string stays one hover away; the detail pane's Information
        // grid always shows it in full.
        versionField.toolTip = model.version.isEmpty ? nil : model.version

        // One spoken phrase per row instead of several stray labels. The chips are
        // part of the row's meaning ("Running", "dep"), so they're spoken too.
        let spoken = ([model.title, model.version]
            + model.pills.map(\.text)
            + [model.subtitle, model.updateAvailable ? "Update available" : ""])
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        setAccessibilityLabel(spoken)
    }

    /// Homebrew cask versions are often `version,build` ("1.1.16,20260425132215").
    /// The build id changes no decision and doubles the column's width, so the row
    /// shows the part a user recognises and keeps the rest in the tooltip.
    static func shortVersion(_ version: String) -> String {
        // Keep empty subsequences: without them a leading comma (",20260425") would
        // surface the build id *as* the version, which is worse than showing the
        // raw string. An empty prefix means there's nothing better to show.
        let head = version.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return head.isEmpty ? version : String(head)
    }

    /// Back-compat path for the search / adopt sheets, which pass a plain image
    /// and an optional colored badge.
    func configure(icon: NSImage?, title: String, subtitle: String, badgeText: String?, badgeColor: NSColor) {
        let leading: HomebrewRowModel.Leading = icon.map { .appIcon($0) } ?? .glyph(symbol: "shippingbox")
        var pills: [PillSpec] = []
        if let badgeText, !badgeText.isEmpty { pills.append(PillSpec(text: badgeText, color: badgeColor)) }
        configure(HomebrewRowModel(leading: leading, title: title, pills: pills, subtitle: subtitle))
    }
}

/// Group-header row ("Casks 16" / "Formulae 227") for the grouped Installed list.
final class HomebrewHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HomebrewHeader")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        // Matches the nav sidebar's group headers, so both lists read as one family
        // instead of two different apps stitched together.
        label.font = Typography.semibold(.subheadline)
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
