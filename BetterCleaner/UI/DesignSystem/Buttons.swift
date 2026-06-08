import AppKit

/// Factory helpers so every screen styles its actions consistently:
/// a prominent accent **primary**, a red **destructive** (Liquid Glass renders
/// `hasDestructiveAction` in red on macOS 26), and a plain **secondary**.
@MainActor
enum Buttons {
    /// Accent-tinted default action (e.g. "Recheck", confirmations). Bound to
    /// Return by default.
    static func primary(_ title: String, target: AnyObject?, action: Selector, key: String = "\r") -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = key
        b.bezelColor = .controlAccentColor
        b.contentTintColor = .white
        return b
    }

    /// Red destructive action (Move to Trash, Uninstall, Forget). Defaults to the
    /// Return key since it's the primary action on its screen.
    static func destructive(_ title: String, target: AnyObject?, action: Selector, key: String = "\r") -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = key
        b.hasDestructiveAction = true
        return b
    }

    /// Neutral bordered action (Refresh, Select All, Prune Languages).
    static func secondary(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }
}
