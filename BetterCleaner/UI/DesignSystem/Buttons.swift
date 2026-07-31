import AppKit

/// Factory helpers for consistent native AppKit actions.
@MainActor
enum Buttons {
    /// Accent-tinted default action (e.g. "Recheck", confirmations). Bound to
    /// Return by default.
    static func primary(_ title: String, target: AnyObject?, action: Selector, key: String = "\r") -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        return button
    }

    /// Red destructive action (Move to Trash, Uninstall, Forget). It deliberately
    /// has no Return shortcut; confirmation dialogs own the safe default action.
    static func destructive(_ title: String, target: AnyObject?, action: Selector, key: String = "") -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.hasDestructiveAction = true
        return button
    }

    /// Neutral bordered action (Refresh, Select All, Prune Languages).
    static func secondary(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// Adds a destructive alert action while making Cancel the Return-key default.
    /// Destructive confirmations must require an explicit click or keyboard choice.
    static func addDestructiveConfirmation(_ title: String, to alert: NSAlert) {
        let destructive = alert.addButton(withTitle: title)
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
    }
}
