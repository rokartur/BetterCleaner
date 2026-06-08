import AppKit
import BetterSettings
import BetterUpdater
import Combine

final class UpdateSettingsViewController: SettingsTabViewController {
    private let updater = GitHubUpdater.shared
    private var cancellables = Set<AnyCancellable>()

    private let statusLabel = NSTextField(labelWithString: "")
    private let lastCheckedLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let cadences = UpdateCheckInterval.selectableCadences

    private let skippedVersionLabel = NSTextField(labelWithString: "")
    private let resetSkippedButton = NSButton(title: "Reset", target: nil, action: nil)

    override func setupContent() {
        let status = addSection(title: "Updates", anchor: "updates")

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        addRow(to: status, title: "BetterCleaner \(AppInfo.version)",
               subtitle: "Build \(AppInfo.build)",
               accessory: statusLabel)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(primaryAction)
        addRow(to: status, title: "Check now",
               subtitle: "Look for a newer release on GitHub.",
               accessory: actionButton)

        lastCheckedLabel.font = .systemFont(ofSize: 12)
        lastCheckedLabel.textColor = .secondaryLabelColor
        lastCheckedLabel.alignment = .right
        addRow(to: status, title: "Last checked", accessory: lastCheckedLabel)

        let options = addSection(title: "Options", anchor: "options")

        intervalPopup.addItems(withTitles: cadences.map { $0.title })
        if let index = cadences.firstIndex(of: updater.checkInterval) {
            intervalPopup.selectItem(at: index)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        addRow(to: options, title: "Check automatically", accessory: intervalPopup)

        addRow(to: options, title: "Download updates automatically",
               accessory: makeSwitch(updater.automaticDownloadEnabled, #selector(autoDownloadChanged(_:))))
        addRow(to: options, title: "Install updates automatically",
               accessory: makeSwitch(updater.automaticInstallEnabled, #selector(autoInstallChanged(_:))))
        addRow(to: options, title: "Include pre-releases",
               accessory: makeSwitch(updater.includePreReleases, #selector(preReleaseChanged(_:))))

        skippedVersionLabel.font = .systemFont(ofSize: 12)
        skippedVersionLabel.textColor = .secondaryLabelColor
        resetSkippedButton.bezelStyle = .rounded
        resetSkippedButton.target = self
        resetSkippedButton.action = #selector(resetSkipped)
        let skippedAccessory = NSStackView(views: [skippedVersionLabel, resetSkippedButton])
        skippedAccessory.orientation = .horizontal
        skippedAccessory.alignment = .centerY
        skippedAccessory.spacing = 8
        addRow(to: options, title: "Skipped version",
               subtitle: "Allow an update you previously skipped to be offered again.",
               accessory: skippedAccessory)

        updater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)

        updater.$skippedVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in self?.renderSkipped(version) }
            .store(in: &cancellables)
    }

    override func prepareForMemoryRelease() {
        cancellables.removeAll()
        super.prepareForMemoryRelease()
    }

    private func makeSwitch(_ on: Bool, _ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = action
        return toggle
    }

    private func render(_ state: UpdateState) {
        lastCheckedLabel.stringValue = updater.lastCheckDescription
        switch state {
        case .idle:
            statusLabel.stringValue = ""
            actionButton.title = "Check for Updates"
        case .checking:
            statusLabel.stringValue = "Checking…"
            actionButton.title = "Checking…"
        case .available(let version, _):
            statusLabel.stringValue = "Update available: \(version)"
            actionButton.title = "View Update"
        case .downloading(let progress):
            statusLabel.stringValue = "Downloading \(Int(progress * 100))%"
            actionButton.title = "Downloading…"
        case .readyToInstall:
            statusLabel.stringValue = "Ready to install"
            actionButton.title = "Restart to Update"
        case .installing(_, let step):
            statusLabel.stringValue = step
            actionButton.title = "Installing…"
        case .error(let message):
            statusLabel.stringValue = "Error: \(message)"
            actionButton.title = "Try Again"
        case .upToDate:
            statusLabel.stringValue = "You're up to date"
            actionButton.title = "Check for Updates"
        }
    }

    private func renderSkipped(_ version: String?) {
        if let version, !version.isEmpty {
            skippedVersionLabel.stringValue = "v\(version)"
            resetSkippedButton.isEnabled = true
        } else {
            skippedVersionLabel.stringValue = "None"
            resetSkippedButton.isEnabled = false
        }
    }

    @objc private func resetSkipped() {
        updater.skippedVersion = nil
    }

    @objc private func primaryAction() {
        UpdateWindowPresenter.shared.show()
        Task { @MainActor in await updater.checkForUpdates(force: true) }
    }

    @objc private func intervalChanged() {
        let index = intervalPopup.indexOfSelectedItem
        guard index >= 0, index < cadences.count else { return }
        updater.setCheckInterval(cadences[index])
    }

    @objc private func autoDownloadChanged(_ sender: NSSwitch) {
        updater.automaticDownloadEnabled = sender.state == .on
    }

    @objc private func autoInstallChanged(_ sender: NSSwitch) {
        updater.automaticInstallEnabled = sender.state == .on
    }

    @objc private func preReleaseChanged(_ sender: NSSwitch) {
        updater.includePreReleases = sender.state == .on
    }
}
