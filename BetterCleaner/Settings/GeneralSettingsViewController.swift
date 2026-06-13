import AppKit
import BetterSettings
import BetterUpdater

final class GeneralSettingsViewController: SettingsTabViewController {
    private let updater = GitHubUpdater.shared
    private let intervalPopup = NSPopUpButton()
    private let cadences = UpdateCheckInterval.selectableCadences

    override func setupContent() {
        let scanning = addSection(title: "Scanning", anchor: "scanning")

        addRow(to: scanning, title: "Include system files",
               subtitle: "Also scan /Library. Removing these requires an admin password.",
               accessory: makeSwitch(Preferences.shared.includeSystemFiles, #selector(includeSystemChanged(_:))))

        addRow(to: scanning, title: "Confirm before deleting",
               accessory: makeSwitch(Preferences.shared.confirmBeforeDelete, #selector(confirmChanged(_:))))

        let uninstall = addSection(title: "Complete Uninstall", anchor: "uninstall")
        addRow(to: uninstall, title: "Stop helper processes",
               subtitle: "Force-quit background helpers that keep running after the app closes.",
               accessory: makeSwitch(Preferences.shared.completeUninstallForceQuit, #selector(forceQuitChanged(_:))))
        addRow(to: uninstall, title: "Reset privacy permissions",
               subtitle: "Clear the app's Camera/Microphone/Accessibility grants. You'll re-grant if reinstalled.",
               accessory: makeSwitch(Preferences.shared.completeUninstallResetPrivacy, #selector(resetPrivacyChanged(_:))))
        addRow(to: uninstall, title: "Remove Keychain items",
               subtitle: "Delete passwords the app saved under its bundle id.",
               accessory: makeSwitch(Preferences.shared.completeUninstallKeychain, #selector(keychainChanged(_:))))
        // Full Disk Access (and every other capability) now lives in the
        // dedicated Permissions section of the sidebar, not buried in Settings.

        let updates = addSection(title: "Updates", anchor: "updates")
        intervalPopup.addItems(withTitles: cadences.map { $0.title })
        if let index = cadences.firstIndex(of: updater.checkInterval) {
            intervalPopup.selectItem(at: index)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        addRow(to: updates, title: "Check for updates",
               subtitle: "How often to look for a newer release on GitHub.",
               accessory: intervalPopup)
        addRow(to: updates, title: "Include pre-releases",
               subtitle: "Get beta builds before they ship to everyone.",
               accessory: makeSwitch(updater.includePreReleases, #selector(preReleaseChanged(_:))))
    }

    private func makeSwitch(_ on: Bool, _ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = action
        return toggle
    }

    @objc private func includeSystemChanged(_ sender: NSSwitch) {
        Preferences.shared.includeSystemFiles = sender.state == .on
    }

    @objc private func confirmChanged(_ sender: NSSwitch) {
        Preferences.shared.confirmBeforeDelete = sender.state == .on
    }

    @objc private func forceQuitChanged(_ sender: NSSwitch) {
        Preferences.shared.completeUninstallForceQuit = sender.state == .on
    }

    @objc private func resetPrivacyChanged(_ sender: NSSwitch) {
        Preferences.shared.completeUninstallResetPrivacy = sender.state == .on
    }

    @objc private func keychainChanged(_ sender: NSSwitch) {
        Preferences.shared.completeUninstallKeychain = sender.state == .on
    }

    @objc private func intervalChanged() {
        let index = intervalPopup.indexOfSelectedItem
        guard index >= 0, index < cadences.count else { return }
        updater.setCheckInterval(cadences[index])
    }

    @objc private func preReleaseChanged(_ sender: NSSwitch) {
        updater.includePreReleases = sender.state == .on
    }
}
