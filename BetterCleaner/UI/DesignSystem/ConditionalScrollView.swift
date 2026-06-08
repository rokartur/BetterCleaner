import AppKit

/// An `NSScrollView` pinned to overlay scrollers, regardless of the system
/// "Show scroll bars" setting (and any later `NSPreferredScrollerStyleDidChange`).
///
/// Why: a *legacy* (always-visible) scroller reserves layout width from the
/// document view the instant it appears. In an outline whose height changes as
/// the user expands/collapses sections, the vertical scroller flickers in and
/// out — and each time it does, the document's fitting width jumps by the
/// scroller width, reflowing every row's columns and indentation. That reads as
/// the list "randomly" rendering with uneven indents. Overlay scrollers float
/// above the content with zero layout width, so the document width stays
/// constant and rows never shift sideways.
///
/// Overriding the getter (and swallowing the setter) is what makes this immune
/// to the user's preference and to AppKit toggling the style at runtime.
final class ConditionalScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { /* ignore: stay overlay so the scroller never reserves width */ }
    }
}
