import AppKit

/// A full-window drop affordance shown while a `.app` is dragged over the window:
/// a translucent veil + a dashed rounded accent border + a centered prompt.
///
/// Purely visual — it stays hidden unless a drag is in progress. The drop itself
/// is handled by the container view that registers for dragged types (a hidden
/// view can't receive drag messages, so the two are deliberately separate).
@MainActor
final class DropZoneOverlayView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Drop an app to uninstall")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let cfg = NSImage.SymbolConfiguration(pointSize: Metrics.dragDropIconSize, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = Typography.semibold(.title3)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        iconView.setAccessibilityElement(false)

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The overlay only exists while a drag is in flight, so its appearance is
        // itself the state change. Announce it as one phrase instead of leaving a
        // sighted-only dashed border to carry the message.
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop an app here to uninstall it")
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Translucent veil so the window content dims behind the prompt.
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        bounds.fill()
        // Dashed rounded accent border, inset from the edges. Plain bezier stroke
        // — native, no CALayer tile drawing.
        let inset = bounds.insetBy(dx: Spacing.xl, dy: Spacing.xl)
        guard inset.width > 0, inset.height > 0 else { return }
        let path = NSBezierPath(roundedRect: inset, xRadius: 18, yRadius: 18)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
