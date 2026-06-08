import AppKit
import BetterSettings

/// Settings tab managing the macOS capabilities BetterCleaner relies on. Full
/// Disk Access shows a live Granted / Not-granted status with a button that jumps
/// to the right System Settings pane; the status re-checks whenever the app
/// regains focus, so toggling it in System Settings and returning updates it
/// without reopening Settings. Replaces the old blocking launch sheet.
final class PermissionsSettingsViewController: SettingsTabViewController {
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let fdaButton = NSButton(title: "", target: nil, action: nil)
    private var wasGranted = false

    override func setupContent() {
        let section = addSection(title: "Permissions", anchor: "permissions")

        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        fdaButton.bezelStyle = .rounded
        fdaButton.target = self
        fdaButton.action = #selector(openFDASettings)
        fdaButton.setContentHuggingPriority(.required, for: .horizontal)

        let accessory = NSStackView(views: [statusIcon, statusLabel, fdaButton])
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = Spacing.sm

        addRow(to: section, title: "Full Disk Access",
               subtitle: "Lets BetterCleaner read the protected parts of your Library (Containers, Mail, Safari) so scans find every leftover. Without it, scans are incomplete.",
               accessory: accessory)

        addRow(to: section, title: "Administrator Password",
               subtitle: "Removing system files in /Library and forgetting package receipts asks for your admin password when it's needed — nothing to enable in advance.")

        wasGranted = FullDiskAccess.isGranted
        refreshStatus()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshStatus),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    override func prepareForMemoryRelease() {
        NotificationCenter.default.removeObserver(self)
        super.prepareForMemoryRelease()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshStatus() {
        let granted = FullDiskAccess.isGranted
        if granted {
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            statusIcon.contentTintColor = .systemGreen
            statusLabel.stringValue = "Granted"
            statusLabel.textColor = .systemGreen
            fdaButton.title = "Open Settings"
        } else {
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not granted")
            statusIcon.contentTintColor = .systemOrange
            statusLabel.stringValue = "Not granted"
            statusLabel.textColor = .systemOrange
            fdaButton.title = "Grant Access"
        }
        // Recovered from missing → granted: re-scan the app list that was gated
        // on it, quietly (don't yank the main window in front of Settings).
        if granted && !wasGranted {
            AppCoordinator.shared.mainController().refreshApps()
        }
        wasGranted = granted
    }

    @objc private func openFDASettings() {
        FullDiskAccess.openSettings()
    }
}
