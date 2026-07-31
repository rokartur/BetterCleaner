import AppKit

/// A flat, native bottom action bar: a 1pt top hairline (an `NSBox` separator)
/// over a horizontal row of controls — leading controls (Select All, status,
/// secondary actions) on the left, a flexible spacer, and the primary /
/// destructive action on the right.
///
/// Stock AppKit only, so every detail pane gets the same plain footer band
/// sitting directly on the window surface. The `init(leading:trailing:)`
/// signature is unchanged, so existing call sites are untouched.
///
/// **The bar collapses itself when it has nothing to offer.** A loading,
/// permission or empty state hides its own controls; a footer left behind with
/// only a stray caption (or a row of disabled buttons) reads as a broken screen.
/// The bar observes its controls' `isHidden` and removes its whole band —
/// hairline included — the moment none of them is visible, so those states end
/// flush at the bottom of the pane instead of against an empty ledge.
@MainActor
final class ActionBarView: NSView {
    /// Vertical stack of [hairline, controls]. An `NSStackView` excludes hidden
    /// arranged subviews from its layout, so hiding both collapses the bar's
    /// height to zero without fighting an explicit height constraint.
    private let column = NSStackView()
    private let separator = NSBox()
    private let controlsRow = NSStackView()
    private let leadingStack = NSStackView()
    private let trailingStack = NSStackView()

    /// KVO tokens for the controls whose visibility drives auto-collapse.
    private var visibilityObservations: [NSKeyValueObservation] = []

    /// - Parameters:
    ///   - leading: controls pinned to the left edge, in order.
    ///   - trailing: controls pinned to the right edge, in order.
    init(leading: [NSView] = [], trailing: [NSView] = []) {
        super.init(frame: .zero)

        // Native top hairline. `NSBox.separator` follows the system separator
        // color and adapts to light/dark on its own — no custom drawing.
        separator.boxType = .separator

        for group in [leadingStack, trailingStack] {
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = Spacing.sm
        }
        leadingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = Spacing.sm
        controlsRow.edgeInsets = NSEdgeInsets(top: Spacing.md, left: Spacing.lg, bottom: Spacing.md, right: Spacing.lg)
        controlsRow.addArrangedSubview(leadingStack)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controlsRow.addArrangedSubview(spacer)
        controlsRow.addArrangedSubview(trailingStack)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(separator)
        column.addArrangedSubview(controlsRow)
        addSubview(column)

        setLeading(leading)
        setTrailing(trailing)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Actions")

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
            controlsRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            // Keep the band comfortably tall enough for a `.rounded` button.
            controlsRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setLeading(_ views: [NSView]) { replace(leadingStack, with: views) }
    func setTrailing(_ views: [NSView]) { replace(trailingStack, with: views) }

    private func replace(_ group: NSStackView, with views: [NSView]) {
        group.arrangedSubviews.forEach { view in
            group.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            group.addArrangedSubview(view)
            if group === leadingStack {
                // Native adaptive behavior: secondary/status controls detach as
                // space tightens while the consequential trailing action remains.
                group.setVisibilityPriority(.detachOnlyIfNecessary, for: view)
            }
        }
        observeControlVisibility()
        updateCollapse()
    }

    /// Re-arm KVO on every control so the bar collapses/expands as screens toggle
    /// their footers, with no call-site bookkeeping.
    private func observeControlVisibility() {
        visibilityObservations = (leadingStack.arrangedSubviews + trailingStack.arrangedSubviews).map { view in
            view.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateCollapse() }
            }
        }
    }

    /// Collapse the whole band — hairline included — when no control is visible.
    private func updateCollapse() {
        let hasVisibleControl = (leadingStack.arrangedSubviews + trailingStack.arrangedSubviews)
            .contains { !$0.isHidden }
        guard separator.isHidden == hasVisibleControl else { return }
        separator.isHidden = !hasVisibleControl
        controlsRow.isHidden = !hasVisibleControl
        isHidden = !hasVisibleControl
    }
}
