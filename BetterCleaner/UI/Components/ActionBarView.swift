import AppKit

/// A flat, native bottom action bar: a 1pt top hairline (an `NSBox` separator)
/// over a horizontal row of controls — leading controls (Select All, status,
/// secondary actions) on the left, a flexible spacer, and the primary /
/// destructive action on the right.
///
/// Replaces the former Liquid-Glass action strip with stock AppKit so every
/// detail pane gets the same plain footer band that sits directly on the window
/// surface. The `init(leading:trailing:)` signature is unchanged, so existing
/// call sites are untouched.
@MainActor
final class ActionBarView: NSView {
    private let stack = NSStackView()

    /// - Parameters:
    ///   - leading: controls pinned to the left edge, in order.
    ///   - trailing: controls pinned to the right edge, in order.
    init(leading: [NSView] = [], trailing: [NSView] = []) {
        super.init(frame: .zero)

        // Native top hairline. `NSBox.separator` follows the system separator
        // color and adapts to light/dark on its own — no custom drawing.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.sm
        stack.edgeInsets = NSEdgeInsets(top: Spacing.sm, left: Spacing.md, bottom: Spacing.sm, right: Spacing.md)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for v in leading { stack.addArrangedSubview(v) }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        for v in trailing { stack.addArrangedSubview(v) }

        addSubview(stack)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Keep the bar comfortably tall enough for a `.rounded` button.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
