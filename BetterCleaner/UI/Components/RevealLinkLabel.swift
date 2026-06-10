import AppKit

/// A path/name label that reads as an actionable link: it underlines while the
/// pointer is over it (with a pointing-hand cursor) and, on click, reveals its
/// `url` in Finder. Falls back to a custom `onClick` when one is set.
///
/// Built as a plain non-editable `NSTextField` that intercepts its own mouse
/// events, so it works inside an outline/table row whose rows aren't selectable.
///
/// Hover is driven by the *actual* pointer position, not just enter/exit events:
/// inside a scroll view the rows move under a stationary cursor (no mouse-moved
/// events fire) and cells are recycled, so relying on `mouseEntered`/`mouseExited`
/// alone leaves a stale underline on whatever row scrolled past the pointer. The
/// label re-checks the real pointer on every scroll tick, on tracking-area
/// rebuilds, and whenever it's reconfigured for a recycled row.
final class RevealLinkLabel: NSTextField {
    /// The file/folder this label points at; a click reveals it in Finder.
    var url: URL? {
        didSet {
            toolTip = url?.path
            // A recycled cell may carry a stale hover from the row it showed
            // before — re-evaluate against where the pointer actually is now.
            syncHoverToPointer()
        }
    }

    /// Overrides the default reveal-in-Finder behavior when set.
    var onClick: (() -> Void)?

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
        // A click recognizer (not mouseDown) — a non-selectable label inside an
        // NSOutlineView/NSTableView never receives mouseDown (the table swallows it
        // for row handling), but a gesture recognizer on the subview still fires.
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
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

    // A non-selectable, non-editable NSTextField declines the mouse (its default
    // hitTest returns nil), so the click recognizer would never fire — the table
    // swallows the click instead. Claim hits inside our frame so left-clicks land.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { syncHoverToPointer() }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    @objc private func handleClick() {
        if let onClick { onClick(); return }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
