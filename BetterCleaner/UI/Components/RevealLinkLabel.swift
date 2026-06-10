import AppKit

/// A name label that reads as an actionable link: it underlines while the pointer
/// is over it (with a pointing-hand cursor). It does NOT handle the click itself —
/// the owning `NSOutlineView`'s single-click `action` reveals the row in Finder,
/// which is reliable for non-selectable rows where a per-view click recognizer is
/// swallowed by the table. This label just provides the hover affordance and
/// deliberately declines hit-testing so the click reaches the table.
///
/// Hover is driven by the *actual* pointer position, not just enter/exit events:
/// inside a scroll view the rows move under a stationary cursor (no mouse-moved
/// events fire) and cells are recycled, so relying on `mouseEntered`/`mouseExited`
/// alone leaves a stale underline on whatever row scrolled past the pointer. The
/// label re-checks the real pointer on every scroll tick, on tracking-area
/// rebuilds, and whenever it's reconfigured for a recycled row.
final class RevealLinkLabel: NSTextField {
    /// The file/folder this label points at; only used for the tooltip now (the
    /// reveal action lives on the enclosing outline view).
    var url: URL? { didSet { toolTip = url?.path; syncHoverToPointer() } }

    private var hoverTracking: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private var isHovering = false {
        didSet { guard isHovering != oldValue else { return }; applyUnderline() }
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var stringValue: String {
        didSet { applyUnderline() }
    }

    /// Rebuild the attributed string, adding an underline only while hovering.
    /// Mirrors the field's own `font`/`textColor`/`lineBreakMode` so it looks
    /// identical to a static label when idle.
    private func applyUnderline() {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = lineBreakMode
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? Typography.caption,
            .foregroundColor: textColor ?? NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        if isHovering { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: stringValue, attributes: attrs)
    }

    /// Set `isHovering` from the live pointer position rather than trusting that an
    /// enter/exit pair fired. `visibleRect` (not `bounds`) so a name scrolled half
    /// behind the header doesn't underline from a pointer over its clipped part.
    private func syncHoverToPointer() {
        guard let window, NSApp.isActive, !isHidden else { isHovering = false; return }
        let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovering = visibleRect.contains(pointInView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Watch the enclosing scroll view: it moves rows under the cursor without
        // firing mouse events, which is exactly when a stale underline appears.
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        observedClipView = nil
        if window != nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(enclosingScrolled),
                name: NSView.boundsDidChangeNotification, object: clip)
            observedClipView = clip
        }
        syncHoverToPointer()
    }

    @objc private func enclosingScrolled() { syncHoverToPointer() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        // `.inVisibleRect` keeps the tracking region pinned to the visible area
        // across scroll/resize without manual rect bookkeeping.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
        // A tracking-area rebuild (layout/scroll) is another moment the cached
        // hover can have gone stale — re-anchor it to the real pointer.
        syncHoverToPointer()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // Decline hit-testing so the click falls through to the outline view, whose
    // single-click `action` reveals the row. (A non-selectable table row swallows
    // a per-view click recognizer, which is why reveal-on-click is done table-side.)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { syncHoverToPointer() }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}
