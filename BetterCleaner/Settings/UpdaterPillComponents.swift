import AppKit

/// Native updater progress used by the About pane. AppKit owns appearance,
/// accessibility, Increased Contrast, and accent-color rendering.
@MainActor
final class UpdaterProgressView: NSView {
    init(progress: Double, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = Typography.medium(.caption1)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = max(0, min(1, progress))

        let stack = NSStackView(views: [label, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
