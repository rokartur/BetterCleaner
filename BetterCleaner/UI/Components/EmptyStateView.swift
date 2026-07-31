import AppKit

/// A centered "nothing here" / "pick something" panel: an SF Symbol over a title
/// and optional message, with an optional action button. Mirrors the modern
/// macOS empty-state look (à la `NSContentUnavailableView`) and replaces the
/// one-off `placeholderLabel`s each screen used to position by hand.
///
/// Two tones keep panes from competing for attention:
/// - **hero** — this pane's whole story (nothing found, permission required,
///   all clear). Full-size glyph, title2 heading, optional action button.
/// - **hint** — a quiet "waiting for you" placeholder in a *secondary* pane
///   (e.g. a detail column whose master list has nothing selected yet). Smaller,
///   dimmer, no heading weight, so it never reads as a second hero next to one.
///
/// The stack sits at ~42% of the pane height rather than dead-center: an
/// optically centered block reads as placed, a mathematically centered one reads
/// as adrift in a void.
@MainActor
final class EmptyStateView: NSView {
    /// Visual weight of the state. See the type doc.
    enum Tone {
        case hero
        case hint
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var actionButton = Buttons.secondary("", target: self, action: #selector(actionTapped))
    private var action: (() -> Void)?
    private var tone: Tone = .hero

    private let stack = NSStackView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    /// Hero glyph — large enough to anchor the pane, small enough not to shout.
    private static let heroIconSize: CGFloat = 34
    /// Hint glyph — reads as punctuation next to the copy, not as an illustration.
    private static let hintIconSize: CGFloat = 22

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; updateAccessibility() }
    }
    var message: String {
        get { messageLabel.stringValue }
        set { messageLabel.stringValue = newValue; messageLabel.isHidden = newValue.isEmpty; updateAccessibility() }
    }

    init(symbol: String = "tray") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.heroIconSize)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: Self.heroIconSize)
        NSLayoutConstraint.activate([iconWidth, iconHeight])

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = Metrics.emptyStateMaxWidth

        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = Metrics.emptyStateMaxWidth
        messageLabel.isHidden = true

        actionButton.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [iconView, titleLabel, messageLabel, actionButton] { stack.addArrangedSubview(view) }
        addSubview(stack)

        // Optical centering: the block's center sits at 42% of the pane height, so
        // it reads as deliberately placed instead of floating in dead space.
        let opticalCenter = NSLayoutConstraint(
            item: stack, attribute: .centerY,
            relatedBy: .equal,
            toItem: self, attribute: .bottom,
            multiplier: 0.42, constant: 0
        )
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            opticalCenter,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Spacing.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Spacing.lg),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.xl)
        ])

        setAccessibilityRole(.group)
        applyTone()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setSymbol(_ name: String) {
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        applySymbolConfiguration()
    }

    /// Configure the whole panel at once. Pass `actionTitle`+`action` to show a
    /// button (e.g. "Open Privacy Settings" on a permissions state).
    ///
    /// - Parameters:
    ///   - tone: `.hero` for the pane's own story, `.hint` for a quiet
    ///     "nothing selected yet" placeholder beside a pane that already has one.
    ///   - actionIsPrimary: render the button as the accent default action. Only
    ///     ever `true` for a *safe* action — an empty state never hosts a
    ///     destructive default.
    func configure(
        symbol: String,
        title: String,
        message: String = "",
        tone: Tone = .hero,
        actionTitle: String? = nil,
        actionIsPrimary: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        applyTone()
        setSymbol(symbol)
        self.title = title
        self.message = message
        self.action = action
        if let actionTitle, action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
            // A default (Return-bound) button is only appropriate for safe
            // actions; destructive work never lives in an empty state.
            actionButton.keyEquivalent = actionIsPrimary ? "\r" : ""
        } else {
            actionButton.isHidden = true
            actionButton.keyEquivalent = ""
        }
        updateAccessibility()
    }

    /// Apply the type scale, tint and rhythm for the active tone.
    private func applyTone() {
        switch tone {
        case .hero:
            iconWidth.constant = Self.heroIconSize
            iconHeight.constant = Self.heroIconSize
            titleLabel.font = Typography.semibold(.title3)
            titleLabel.textColor = .labelColor
            messageLabel.font = Typography.subheadline
            messageLabel.textColor = .secondaryLabelColor
            stack.spacing = Spacing.sm
            stack.setCustomSpacing(Spacing.md, after: iconView)
            stack.setCustomSpacing(Spacing.lg, after: messageLabel)
        case .hint:
            iconWidth.constant = Self.hintIconSize
            iconHeight.constant = Self.hintIconSize
            titleLabel.font = Typography.medium(.body)
            titleLabel.textColor = .secondaryLabelColor
            messageLabel.font = Typography.footnote
            messageLabel.textColor = .tertiaryLabelColor
            stack.spacing = Spacing.xs
            stack.setCustomSpacing(Spacing.sm, after: iconView)
            stack.setCustomSpacing(Spacing.md, after: messageLabel)
        }
        applySymbolConfiguration()
    }

    /// Hierarchical rendering keeps a multi-layer SF Symbol legible at a calm
    /// single tint instead of flattening it to a solid silhouette.
    private func applySymbolConfiguration() {
        let size = tone == .hero ? Self.heroIconSize : Self.hintIconSize
        let base = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        iconView.symbolConfiguration = base.applying(.preferringHierarchical())
        iconView.contentTintColor = tone == .hero ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// VoiceOver reads the state as one sentence instead of three stray labels.
    private func updateAccessibility() {
        let parts = [titleLabel.stringValue, messageLabel.isHidden ? "" : messageLabel.stringValue]
        setAccessibilityLabel(parts.filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @objc private func actionTapped() { action?() }
}
