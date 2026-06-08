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

        messageLabel.font = .systemFont(ofSize: Typography.body.pointSize, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1

        bar.style = .bar
        bar.controlSize = .regular
        bar.minValue = 0
        bar.maxValue = 1

        percentLabel.font = Typography.monospacedDigit(.subheadline, weight: .medium)
        percentLabel.textColor = .tertiaryLabelColor
        percentLabel.alignment = .center

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.sm + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [spinner, messageLabel, bar, percentLabel] { stack.addArrangedSubview(v) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.xl),
            bar.widthAnchor.constraint(equalToConstant: 220),
        ])
        isHidden = true
    }

    // MARK: - API

    /// Animated barber-pole bar + spinner for scans whose total isn't known.
    func startIndeterminate(_ message: String) {
        messageLabel.stringValue = message
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        percentLabel.isHidden = true
        spinner.startAnimation(nil)
        isHidden = false
    }

    /// 0–100% fill + percent for scans that report fractional progress.
    func startDeterminate(_ message: String) {
        messageLabel.stringValue = message
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = 0
        percentLabel.stringValue = "0%"
        percentLabel.isHidden = false
        spinner.startAnimation(nil)
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            bar.animator().doubleValue = clamped
        }
        percentLabel.stringValue = "\(Int((clamped * 100).rounded()))%"
    }

    func stop() {
        spinner.stopAnimation(nil)
        bar.stopAnimation(nil)
        isHidden = true
    }
}
