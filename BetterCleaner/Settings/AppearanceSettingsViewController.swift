import AppKit
import BetterSettings

final class AppearanceSettingsViewController: SettingsTabViewController {
    private let themePopup = NSPopUpButton()

    override func setupContent() {
        let section = addSection(title: "Appearance", anchor: "appearance")
        themePopup.addItems(withTitles: AppTheme.allCases.map { $0.title })
        themePopup.selectItem(at: Preferences.shared.theme.rawValue)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        addRow(to: section, title: "Theme",
               subtitle: "Match the system appearance or force light/dark.",
               accessory: themePopup)

        addRow(to: section, title: "Accent color",
               subtitle: "Follows the accent color set in System Settings → Appearance.",
               accessory: nil)
    }

    @objc private func themeChanged() {
        let index = themePopup.indexOfSelectedItem
        guard index >= 0, let theme = AppTheme(rawValue: index) else { return }
        Preferences.shared.theme = theme
    }
}
