import AppKit
import BetterSettings
import BetterShortcuts

final class ShortcutsSettingsViewController: SettingsTabViewController {
    override func setupContent() {
        let section = addSection(title: "Global Shortcuts", anchor: "shortcuts")
        for name in AppShortcuts.all {
            let recorder = BetterShortcuts.RecorderCocoa(for: name)
            addRow(to: section, title: AppShortcuts.title(for: name), accessory: recorder)
        }
    }
}
