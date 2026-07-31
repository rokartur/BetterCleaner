import AppKit
import BetterSettings
import BetterUpdater
import Combine

final class AboutSettingsViewController: SettingsTabViewController {

    private let updater = GitHubUpdater.shared
    private var cancellables = Set<AnyCancellable>()
    private var upToDateResetTask: Task<Void, Never>?

    private let pillContainer = NSView()
    private weak var activePill: NSView?

    override func setupContent() {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let nameLabel = NSTextField(labelWithString: AppInfo.displayName)
        nameLabel.font = Typography.semibold(.title3)

        let versionLabel = NSTextField(labelWithString: "Version \(AppInfo.version) (\(AppInfo.build))")
        versionLabel.font = Typography.caption
        versionLabel.textColor = .secondaryLabelColor

        let taglineLabel = NSTextField(labelWithString: "Find and remove the files apps leave behind.")
        taglineLabel.font = Typography.caption
        taglineLabel.textColor = .secondaryLabelColor

        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let header = NSStackView(views: [iconView, nameLabel, versionLabel, taglineLabel, pillContainer])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        header.setCustomSpacing(14, after: taglineLabel)
        addArrangedSubview(header)

        let links = addSection(title: nil, anchor: "links")
        let githubButton = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .rounded
        addRow(to: links, title: "Source code", accessory: githubButton)

        bindUpdater()
        renderPill(updater.state, animated: false)
    }

    override func prepareForMemoryRelease() {
        cancellables.removeAll()
        upToDateResetTask?.cancel()
        upToDateResetTask = nil
        super.prepareForMemoryRelease()
    }

    deinit {
        upToDateResetTask?.cancel()
    }

    // MARK: - Updater binding

    private func bindUpdater() {
        updater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleStateChange(state) }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: UpdateState) {
        if case .upToDate = state {
            scheduleUpToDateReset()
        } else {
            upToDateResetTask?.cancel()
            upToDateResetTask = nil
        }
        renderPill(state, animated: true)
    }

    private func scheduleUpToDateReset() {
        upToDateResetTask?.cancel()
        upToDateResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.updater.resetToIdle()
        }
    }

    // MARK: - Pill rendering

    private func renderPill(_ state: UpdateState, animated: Bool) {
        let pill: NSView

        switch state {
        case .idle:
            pill = makeActionButton(
                text: "Check for Updates",
                iconName: "arrow.triangle.2.circlepath",
                actionTag: 0
            )

        case .checking:
            pill = makeLoadingView(text: "Checking…")

        case .upToDate:
            pill = makeStatusView(
                iconName: "checkmark.circle.fill",
                iconColor: .systemGreen,
                text: "You're up to date!"
            )

        case .available(let version, _):
            pill = makeActionButton(
                text: "v\(version) — View Update",
                iconName: "arrow.down.circle",
                actionTag: 1
            )

        case .downloading(let progress):
            pill = UpdaterProgressView(
                progress: progress,
                text: "Downloading \(Int(progress * 100))%"
            )

        case .installing(let progress, let step):
            let text = step.isEmpty ? "Installing \(Int(progress * 100))%" : step
            pill = UpdaterProgressView(progress: progress, text: text)

        case .readyToInstall:
            pill = makeActionButton(
                text: "Restart to Update",
                iconName: "arrow.clockwise.circle",
                actionTag: 1
            )

        case .error(let message):
            pill = makeActionButton(
                text: message,
                iconName: "exclamationmark.triangle",
                actionTag: 0
            )
        }

        swapPill(to: pill, animated: animated)
    }

    private func swapPill(to pill: NSView, animated: Bool) {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: pillContainer.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: pillContainer.leadingAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: pillContainer.trailingAnchor),
        ])

        let previous = activePill
        activePill = pill

        // Reduce Motion swaps the pill instantly. The crossfade only explains the
        // state change; the new pill's text carries the meaning on its own, so
        // dropping the motion loses nothing.
        guard animated, view.window != nil, previous != nil, !Motion.isReduced else {
            previous?.removeFromSuperview()
            return
        }

        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            previous?.animator().alphaValue = 0
            pill.animator().alphaValue = 1
        }, completionHandler: { [weak previous] in
            previous?.removeFromSuperview()
        })
    }

    private func makeActionButton(text: String, iconName: String, actionTag: Int) -> NSButton {
        let button = Buttons.secondary(text, target: self, action: #selector(updaterAction(_:)))
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.tag = actionTag
        return button
    }

    @objc private func updaterAction(_ sender: NSButton) {
        if sender.tag == 1 {
            UpdateWindowPresenter.shared.show()
        } else {
            Task { await updater.checkForUpdates(force: true) }
        }
    }

    private func makeStatusView(iconName: String, iconColor: NSColor, text: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = iconColor
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = Typography.medium(.subheadline)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeLoadingView(text: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.font = Typography.medium(.subheadline)
        label.textColor = .labelColor

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/rokartur/BetterCleaner") {
            NSWorkspace.shared.open(url)
        }
    }
}
