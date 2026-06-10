import AppKit

/// A path/name label that reads as an actionable link: it underlines while the
/// pointer is over it (with a pointing-hand cursor) and, on click, reveals its
/// `url` in Finder. Falls back to a custom `onClick` when one is set.
///
/// Built as a plain non-editable `NSTextField` that intercepts its own mouse
/// events, so it works inside an outline/table row whose rows aren't selectable.
final class RevealLinkLabel: NSTextField {
    /// The file/folder this label points at; a click reveals it in Finder.
    var url: URL? { didSet { toolTip = url?.path } }

    /// Overrides the default reveal-in-Finder behavior when set.
    var onClick: (() -> Void)?

    private var hoverTracking: NSTrackingArea?
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
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

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    @objc private func handleClick() {
        if let onClick { onClick(); return }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
