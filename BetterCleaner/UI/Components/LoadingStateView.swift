import AppKit

/// Shared, polished loading state used by every section's detail pane so the
/// app shows one consistent "working…" look instead of an ad-hoc tiny spinner.
///
/// A centered message sits above a progress bar that is either an animated
/// barber-pole (indeterminate — most scans, whose total isn't known up front) or
/// a smooth 0–100% fill with a percent readout (determinate — the per-app and
/// orphan scans that report progress). An optional spinning glyph adds motion so
/// the state never looks frozen.
@MainActor
final class LoadingStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        messageLabel.font = Typography.medium(.body)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1

        bar.style = .bar
        bar.controlSize = .regular
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true

        percentLabel.font = Typography.monospacedDigit(.subheadline, weight: .medium)
        percentLabel.textColor = .tertiaryLabelColor
        percentLabel.alignment = .center
        percentLabel.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [spinner, messageLabel, bar, percentLabel] { stack.addArrangedSubview(view) }
        addSubview(stack)

        // Same optical centre as EmptyStateView (42% of pane height), so a pane
        // doesn't visibly shift its content upward as loading gives way to results
        // or to an empty state.
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
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.xl),
            bar.widthAnchor.constraint(equalToConstant: 220),
        ])
        isHidden = true
    }

    // MARK: - API

    /// A single native spinner for work whose total isn't known.
    func startIndeterminate(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.setAccessibilityLabel(message)
        bar.stopAnimation(nil)
        bar.isHidden = true
        percentLabel.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        isHidden = false
    }

    /// 0–100% fill + percent for scans that report fractional progress.
    func startDeterminate(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.setAccessibilityLabel(message)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bar.stopAnimation(nil)
        bar.isHidden = false
        bar.isIndeterminate = false
        bar.doubleValue = 0
        percentLabel.stringValue = "0%"
        percentLabel.isHidden = false
        isHidden = false
    }

    /// Update the visible message without changing the progress mode (e.g. the
    /// per-step text during a complete uninstall).
    func setMessage(_ message: String) {
        messageLabel.stringValue = message
    }

    /// Drive the determinate bar (0…1) with a smooth fill animation + percent.
    func update(_ fraction: Double) {
        guard !isHidden, !bar.isIndeterminate else { return }
        let clamped = max(0, min(1, fraction))
        let percent = Int((clamped * 100).rounded())
        Motion.animate { [bar] in bar.animator().doubleValue = clamped }
        percentLabel.stringValue = "\(percent)%"
        bar.setAccessibilityValue(percent)
    }

    func stop() {
        spinner.stopAnimation(nil)
        bar.stopAnimation(nil)
        spinner.isHidden = false
        bar.isHidden = true
        percentLabel.isHidden = true
        isHidden = true
    }
}
