import AppKit

/// Builds and presents the Homebrew "maintenance" menu (the … button): update,
/// upgrade-all, cleanup, autoremove, Brewfile import/export, adopt apps, and the CVE
/// scan. Long operations run in the streaming progress sheet; cleanup/autoremove
/// first show a dry-run preview the user confirms.
///
/// Retained for the lifetime of the menu interaction via a static reference so any
/// asynchronous action survives the `popUp` returning.
@MainActor
final class HomebrewMaintenanceMenu: NSObject {
    private weak var presenter: NSViewController?
    private let onChanged: () -> Void
    private static var retained: HomebrewMaintenanceMenu?

    private init(presenter: NSViewController, onChanged: @escaping () -> Void) {
        self.presenter = presenter
        self.onChanged = onChanged
    }

    static func present(from anchor: NSButton, presenter: NSViewController, onChanged: @escaping () -> Void) {
        let controller = HomebrewMaintenanceMenu(presenter: presenter, onChanged: onChanged)
        retained = controller
        controller.show(from: anchor)
    }

    private func show(from anchor: NSButton) {
        let menu = NSMenu()
        add(menu, "Update Homebrew", #selector(update))
        add(menu, "Upgrade All", #selector(upgradeAll))
        add(menu, "Upgrade All (incl. auto-update casks)", #selector(upgradeAllGreedy))
        menu.addItem(.separator())
        add(menu, "Clean Up Cache…", #selector(cleanup))
        add(menu, "Remove Unused Dependencies…", #selector(autoremove))
        menu.addItem(.separator())
        add(menu, "Export Brewfile…", #selector(exportBrewfile))
        add(menu, "Import Brewfile…", #selector(importBrewfile))
        menu.addItem(.separator())
        add(menu, "Adopt Installed Apps…", #selector(adoptApps))
        add(menu, "Scan for Vulnerabilities…", #selector(scanVulnerabilities))

        let origin = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Simple mutations

    @objc private func update() { runMutation("Updating Homebrew…", HomebrewActions.updateArgs()) }
    @objc private func upgradeAll() { runMutation("Upgrading all packages…", HomebrewActions.upgradeAllArgs(greedy: false)) }
    @objc private func upgradeAllGreedy() { runMutation("Upgrading all packages…", HomebrewActions.upgradeAllArgs(greedy: true)) }

    // MARK: - Preview-then-confirm mutations

    @objc private func cleanup() {
        previewThenRun(
            title: "Clean up Homebrew?",
            preview: { HomebrewService.cleanupPreview() },
            confirm: "Clean Up",
            runTitle: "Cleaning up…",
            args: HomebrewActions.cleanupArgs()
        )
    }

    @objc private func autoremove() {
        previewThenRun(
            title: "Remove unused dependencies?",
            preview: {
                let names = HomebrewService.autoremovePreview()
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

    @objc private func scanVulnerabilities() {
        guard let presenter else { return }
        let vc = HomebrewVulnerabilityViewController()
        presenter.presentAsSheet(vc)
    }

    // MARK: - Helpers

    private func previewThenRun(title: String, preview: @escaping () -> String,
                                confirm: String, runTitle: String, args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = preview()
            DispatchQueue.main.async {
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = text.isEmpty ? "Nothing to do." : text
                if text.isEmpty {
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                alert.addButton(withTitle: confirm)
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.runMutation(runTitle, args)
            }
        }
    }

    private func runMutation(_ title: String, _ args: [String]) {
        guard let presenter else { return }
        let sheet = HomebrewProgressViewController(title: title, arguments: args) { [onChanged] success in
            if success { onChanged() }
        }
        presenter.presentAsSheet(sheet)
    }
}
