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
    /// Leading glyph on the summary line, shown only for status tones (permission
    /// required, partial result) so those never read as an ordinary gray subtitle.
    private let statusIcon = NSImageView()
    /// Emphasized trailing metric ("4.31 GB") rendered beside the plain summary.
    private let metricLabel = NSTextField(labelWithString: "")
    /// Kept so empty lines collapse: the toolbar now carries the page title, so a
    /// header often shows only a summary (or nothing) and must not reserve height.
    private let summaryRow = NSStackView()

    /// One image view serves both modes — a tinted template symbol or a rounded
    /// full-color app icon. NSStackView collapses it when hidden, so a badge-less
    /// header renders with no leading gap.
    private let iconView = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    private static let sectionIconSize: CGFloat = 26
    /// Compact enough to leave the 660pt default window to its content, large
    /// enough to read as the page's subject.
    private static let heroIconSize: CGFloat = 44
    private static let heroIconCorner: CGFloat = 10

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; titleLabel.isHidden = newValue.isEmpty }
    }
    /// Plain secondary line. Setting it clears any status tone or metric, so a
    /// page can't inherit a stale "Permission required" glyph after a good scan.
    var summary: String {
        get { summaryLabel.stringValue }
        set { setSummary(newValue) }
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
        // Born empty → born collapsed, same as the summary row below.
        titleLabel.isHidden = true

        summaryLabel.font = Typography.subheadline
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1

        // The recoverable size is the number the user actually decides on, so it
        // carries label color, semibold weight and tabular digits — it stays put
        // as totals change instead of reflowing the line.
        metricLabel.font = Typography.monospacedDigit(.subheadline, weight: .semibold)
        metricLabel.textColor = .labelColor
        metricLabel.maximumNumberOfLines = 1
        metricLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metricLabel.isHidden = true

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        statusIcon.setAccessibilityElement(false)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.isHidden = true

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
        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.sectionIconSize)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: Self.sectionIconSize)
        NSLayoutConstraint.activate([iconWidth, iconHeight])

        // Symbol + summary + emphasized metric on one line; NSStackView collapses
        // the glyph and the metric when hidden, so a plain summary has no gap.
        for item in [statusIcon, summaryLabel, metricLabel] { summaryRow.addArrangedSubview(item) }
        summaryRow.isHidden = true
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = Spacing.xs

        let textStack = NSStackView(views: [titleLabel, summaryRow, detailLabel])
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

    /// Secondary line as a plain lead-in plus an optional emphasized metric —
    /// e.g. `setSummary("128 items · ", metric: "4.31 GB")`. The metric is what
    /// the user weighs the action against, so it carries the visual weight.
    func setSummary(_ text: String, metric: String? = nil) {
        statusIcon.isHidden = true
        summaryLabel.stringValue = text
        summaryLabel.textColor = .secondaryLabelColor
        metricLabel.stringValue = metric ?? ""
        metricLabel.isHidden = (metric ?? "").isEmpty
        updateSummaryAccessibility()
    }

    /// Attention-toned secondary line (symbol + text) for permission gates and
    /// partial results. The glyph carries the meaning alongside the tint, so the
    /// state survives grayscale and Increased Contrast.
    func setStatus(_ text: String, symbol: String, tint: NSColor = .secondaryLabelColor) {
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = tint
        statusIcon.isHidden = false
        summaryLabel.stringValue = text
        summaryLabel.textColor = tint
        metricLabel.isHidden = true
        metricLabel.stringValue = ""
        updateSummaryAccessibility()
    }

    /// VoiceOver reads summary + metric as one phrase rather than two disconnected
    /// labels ("128 items" … "4.31 GB").
    private func updateSummaryAccessibility() {
        let spoken = [summaryLabel.stringValue, metricLabel.isHidden ? "" : metricLabel.stringValue]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        summaryLabel.setAccessibilityLabel(spoken.isEmpty ? nil : spoken)
        metricLabel.setAccessibilityElement(false)
        summaryRow.isHidden = statusIcon.isHidden && summaryLabel.stringValue.isEmpty && metricLabel.isHidden
    }

    // MARK: - Badge API

    /// Section mode: a plain monochrome SF Symbol (Junk / Orphaned / Packages /
    /// Development / History). The symbol comes from `NavCatalog` so the header
    /// and the sidebar row can't drift.
    func setBadge(symbol: String) {
        mode = .section
        applyMode()
        let config = NSImage.SymbolConfiguration(pointSize: Self.sectionIconSize * 0.82, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = .labelColor
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
