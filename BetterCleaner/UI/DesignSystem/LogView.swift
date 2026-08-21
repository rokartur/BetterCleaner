import AppKit

/// The read-only monospaced log in a bezelled scroll view that every panel with
/// long output uses: Homebrew command output, `brew doctor`, and the removal
/// report.
///
/// Configures a pair the caller owns rather than making one, because callers
/// keep their own references to stream text in and to constrain the scroll view.
enum LogView {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The log is the panel's content, not decoration, so it is always named:
    /// VoiceOver should reach it as the output, not as an unlabelled text area.
    static func configure(_ textView: NSTextView, in scrollView: NSScrollView, accessibilityLabel: String) {
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = font
        textView.textContainerInset = NSSize(width: Spacing.sm, height: Spacing.sm)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // A fresh `NSTextView()` has a zero frame; without a growth range it keeps
        // that height and nothing renders.
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView
    }
}
