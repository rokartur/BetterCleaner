import AppKit

/// Builds and presents the Homebrew "maintenance" menu (the … button): update,
/// upgrade-all, cleanup, autoremove, Brewfile import/export, and adopt apps.
/// Long operations run in the streaming progress sheet; cleanup/autoremove
/// first show a dry-run preview the user confirms.
@MainActor
final class HomebrewMaintenanceMenu: NSObject {
    private weak var presenter: NSViewController?
    private let onChanged: () -> Void
    /// Routes to a full-width Homebrew page (Auto Update / Maintenance). These used
    /// to be sidebar rows; they're maintenance settings, so they belong beside the
    /// other maintenance commands rather than in the app's primary navigation.
    private let onOpenPage: (String) -> Void

    init(presenter: NSViewController,
                 onChanged: @escaping () -> Void,
                 onOpenPage: @escaping (String) -> Void) {
        self.presenter = presenter
        self.onChanged = onChanged
        self.onOpenPage = onOpenPage
    }

    static func present(from anchor: NSButton,
                        presenter: NSViewController,
                        onOpenPage: @escaping (String) -> Void,
                        onChanged: @escaping () -> Void) {
        let controller = HomebrewMaintenanceMenu(presenter: presenter,
                                                 onChanged: onChanged,
                                                 onOpenPage: onOpenPage)
        controller.show(from: anchor)
    }

    private func show(from anchor: NSButton) {
        let menu = NSMenu()
        add(menu, "Update Homebrew", #selector(update))
        add(menu, "Upgrade All Outdated", #selector(upgradeAll))
        menu.addItem(.separator())
        add(menu, "Clean Up Cache…", #selector(cleanup))
        add(menu, "Remove Unused Dependencies…", #selector(autoremove))
        menu.addItem(.separator())
        add(menu, "Export Brewfile…", #selector(exportBrewfile))
        add(menu, "Import Brewfile…", #selector(importBrewfile))
        menu.addItem(.separator())
        add(menu, "Adopt Installed Apps…", #selector(adoptApps))
        menu.addItem(.separator())
        add(menu, "Automatic Updates…", #selector(openAutoUpdate))
        add(menu, "Maintenance & Health…", #selector(openMaintenance))

        let origin = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    // MARK: - Full-width pages

    @objc private func openAutoUpdate() { onOpenPage("brew.autoupdate") }
    @objc private func openMaintenance() { onOpenPage("brew.maintenance") }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Simple mutations

    @objc private func update() { runMutation("Updating Homebrew…", HomebrewActions.updateArgs()) }
    @objc private func upgradeAll() {
        performPreparation({
            try HomebrewService.installedPackages().filter(\.isOutdated)
        }) { result in
            switch result {
            case .failure(let error):
                self.showAlert("Couldn't load updates", error.localizedDescription)
            case .success(let packages) where packages.isEmpty:
                self.showAlert("Homebrew is up to date", "No outdated packages were found.")
            case .success(let packages):
                self.runMutation("Upgrading \(packages.count) packages…",
                                 packages.map(HomebrewActions.upgradePlan))
            }
        }
    }

    // MARK: - Preview-then-confirm mutations

    @objc private func cleanup() {
        previewThenRun(
            title: "Clean up Homebrew?",
            preview: { try HomebrewService.cleanupPreview() },
            confirm: "Clean Up",
            runTitle: "Cleaning up…",
            args: HomebrewActions.cleanupArgs()
        )
    }

    @objc private func autoremove() {
        previewThenRun(
            title: "Remove unused dependencies?",
            preview: {
                let names = try HomebrewService.autoremovePreview()
                return names.isEmpty ? "" : "These packages are no longer needed:\n\n" + names.joined(separator: ", ")
            },
            confirm: "Remove",
            runTitle: "Removing unused dependencies…",
            args: HomebrewActions.autoremoveArgs()
        )
    }

    // MARK: - Brewfile

    @objc private func exportBrewfile() {
        let panel = NSSavePanel()
        panel.title = "Export Brewfile"
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runMutation("Exporting Brewfile…", HomebrewActions.bundleDumpArgs(file: url.path))
    }

    @objc private func importBrewfile() {
        let panel = NSOpenPanel()
        panel.title = "Import Brewfile"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runMutation("Installing from Brewfile…", HomebrewActions.bundleInstallArgs(file: url.path))
    }

    // MARK: - Advanced sheets

    @objc private func adoptApps() {
        guard let presenter else { return }
        let vc = HomebrewAdoptViewController { [onChanged] in onChanged() }
        presenter.presentAsSheet(vc)
    }

    // MARK: - Helpers

    func performPreparation<Value>(_ work: @escaping () throws -> Value,
                                   completion: @escaping (Result<Value, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [self] in
                withExtendedLifetime(self) { completion(result) }
            }
        }
    }

    private func previewThenRun(title: String, preview: @escaping () throws -> String,
                                confirm: String, runTitle: String, args: [String]) {
        performPreparation(preview) { result in
            guard case .success(let text) = result else {
                if case .failure(let error) = result {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't prepare Homebrew preview"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text.isEmpty ? "Nothing to do." : text
            if text.isEmpty {
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            Buttons.addDestructiveConfirmation(confirm, to: alert)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.runMutation(runTitle, args)
        }
    }

    private func runMutation(_ title: String, _ args: [String]) {
        runMutation(title, [HomebrewCommandPlan(arguments: args)])
    }

    private func runMutation(_ title: String, _ plans: [HomebrewCommandPlan]) {
        guard let presenter else { return }
        let sheet = HomebrewProgressViewController(title: title, plans: plans) { [onChanged] success in
            if success { onChanged() }
        }
        presenter.presentAsSheet(sheet)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
