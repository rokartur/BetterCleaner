import AppKit

/// A centered "nothing here" / "pick something" panel: a large SF Symbol over a
/// title and optional message, with an optional action button. Mirrors the
/// modern macOS empty-state look (à la `NSContentUnavailableView`) and replaces
/// the one-off `placeholderLabel`s each screen used to position by hand.
@MainActor
final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var actionButton = Buttons.secondary("", target: self, action: #selector(actionTapped))
    private var action: (() -> Void)?

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }
    var message: String {
        get { messageLabel.stringValue }
        set { messageLabel.stringValue = newValue; messageLabel.isHidden = newValue.isEmpty }
    }

    init(symbol: String = "tray") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 38, weight: .regular)
        iconView.contentTintColor = .tertiaryLabelColor

        titleLabel.font = Typography.semibold(.title3)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel.font = Typography.subheadline
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 320
        messageLabel.isHidden = true

        actionButton.isHidden = true

        let stack = NSStackView(views: [iconView, titleLabel, messageLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.sm
        stack.setCustomSpacing(Spacing.md, after: iconView)
        stack.setCustomSpacing(Spacing.lg, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.xl),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setSymbol(_ name: String) {
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Configure the whole panel at once. Pass `actionTitle`+`action` to show a
    /// button (e.g. "Open Settings" on a permissions empty state).
    func configure(symbol: String, title: String, message: String = "", actionTitle: String? = nil, action: (() -> Void)? = nil) {
        setSymbol(symbol)
        self.title = title
        self.message = message
        self.action = action
        if let actionTitle, action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func actionTapped() { action?() }
}
