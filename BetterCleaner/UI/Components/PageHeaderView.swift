import AppKit

/// Standard detail-pane header. A leading icon next to a title over a secondary
/// summary line and an optional footnote `detail` line.
///
/// The icon has two native modes, switched by which `setBadge` was called last:
/// - **section** — a plain tinted SF Symbol (`NSImageView` template image tinted
///   with the page's `NavCatalog` color). No tile, gradient, or shadow.
/// - **app hero** — the real app icon, large and rounded (Applications detail).
///
/// `clearBadge()` hides the icon and resets to the smaller section scale, so a
/// junk/orphan page can never inherit the hero size after an app was shown.
@MainActor
final class PageHeaderView: NSView {
    private enum Mode { case section, appHero }
    private var mode: Mode = .section

    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// One image view serves both modes — a tinted template symbol or a rounded
    /// full-color app icon. NSStackView collapses it when hidden, so a badge-less
    /// header renders with no leading gap.
    private let iconView = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    private static let sectionIconSize: CGFloat = 26
    private static let heroIconSize: CGFloat = 52
    private static let heroIconCorner: CGFloat = 12

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }
    var summary: String {
        get { summaryLabel.stringValue }
        set { summaryLabel.stringValue = newValue }
    }
    /// Optional third footnote line (e.g. a receipt path). Empty hides it.
    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue; detailLabel.isHidden = newValue.isEmpty }
    }

    /// Truncation mode for the title (tail by default; `.byTruncatingMiddle` for
    /// long bundle-id style titles).
    init(titleTruncation: NSLineBreakMode = .byTruncatingTail) {
        super.init(frame: .zero)

        titleLabel.font = Typography.semibold(.title2)
        titleLabel.lineBreakMode = titleTruncation
        titleLabel.maximumNumberOfLines = 1

        summaryLabel.font = Typography.subheadline
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1

        detailLabel.font = Typography.footnote
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        iconView.isHidden = true
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.sectionIconSize)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: Self.sectionIconSize)
        NSLayoutConstraint.activate([iconWidth, iconHeight])

        let textStack = NSStackView(views: [titleLabel, summaryLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.xs

        let rootStack = NSStackView(views: [iconView, textStack])
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = Spacing.md
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Text API

    func configure(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }

    // MARK: - Badge API

    /// Section mode: a plain tinted SF Symbol (Junk / Orphaned / Packages /
    /// Development / History). Tint + symbol come from `NavCatalog` so the header
    /// and toolbar page menu can't drift.
    func setBadge(symbol: String, tint: NSColor) {
        mode = .section
        applyMode()
        let config = NSImage.SymbolConfiguration(pointSize: Self.sectionIconSize * 0.82, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = tint
        iconView.layer?.cornerRadius = 0
        iconView.isHidden = (image == nil)
    }

    /// App-hero mode: the real rounded app icon (Applications detail pane).
    func setBadge(appIcon: NSImage?) {
        mode = .appHero
        applyMode()
        iconView.contentTintColor = nil
        appIcon?.isTemplate = false
        iconView.image = appIcon
        iconView.layer?.cornerRadius = Self.heroIconCorner
        iconView.isHidden = (appIcon == nil)
    }

    func clearBadge() {
        iconView.image = nil
        iconView.isHidden = true
        mode = .section
        applyMode()
    }

    /// Resize the icon slot + scale the title to the active mode.
    private func applyMode() {
        switch mode {
        case .section:
            iconWidth.constant = Self.sectionIconSize
            iconHeight.constant = Self.sectionIconSize
            titleLabel.font = Typography.semibold(.title2)
        case .appHero:
            iconWidth.constant = Self.heroIconSize
            iconHeight.constant = Self.heroIconSize
            titleLabel.font = Typography.semibold(.title1)
        }
    }
}
