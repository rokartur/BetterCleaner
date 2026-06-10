import AppKit
import BetterUpdater
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.shared.applyTheme()

        // Configure the updater before any BetterUpdater type is touched.
        // NOTE: transitional pinned key + manifestRequired:false until the
        // rokartur/BetterCleaner release-signing pipeline exists (see README).
        BetterUpdater.bootstrap(configuration: .init(
            owner: "rokartur",
            repo: "BetterCleaner",
            displayName: AppInfo.displayName,
            bundleIdentifier: "com.rokartur.BetterCleaner",
            pinnedPublicKeyBase64: "L6887IB9AHc2yQ8AqEX/R5H/CqrvamcYtEDKyezRTq8=",
            userAgentProduct: "BetterCleaner-Updater",
            manifestRequired: false
        ))

        // Refuse to keep running from a translocated/quarantined mount — App
        // Translocation randomizes the path, so in-place self-updates would land
        // in a throwaway copy. Nudge the user to move the app to /Applications and
        // relaunch from there. When this returns false the app is relaunching from
        // the moved copy.
        guard AppTranslocation.guardLaunchLocation() else { return }

        AppCoordinator.shared.showMainWindow()

        // Sentinel: watch the Trash for drag-to-Trash uninstalls (opt-in). Posts a
        // notification offering to clean leftovers; clicking it surfaces the app.
        UNUserNotificationCenter.current().delegate = self
        TrashWatcher.shared.setEnabled(Preferences.shared.watchTrashForLeftovers)

        Task { @MainActor in
            // Touch the singleton so it boots its scheduled auto-check task,
            // then run an opportunistic, non-forced check at launch.
            _ = GitHubUpdater.shared
            await GitHubUpdater.shared.checkForUpdates(force: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.showMainWindow()
        return true
    }

    /// Handle the `bettercleaner://` deep link emitted by the Finder extension's
    /// "Uninstall with BetterCleaner" menu item — `bettercleaner://uninstallApp?path=…`.
    /// Surfaces the app and selects it for uninstall.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "bettercleaner" {
            guard url.host == "uninstallApp" else { continue }
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
            guard let path, !path.isEmpty else { continue }
            AppCoordinator.shared.uninstall(name: nil, path: path, matchType: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        SettingsWindowPresenter.shared.show()
    }

    @objc private func checkForUpdates() {
        UpdateWindowPresenter.shared.show()
        Task { @MainActor in await GitHubUpdater.shared.checkForUpdates(force: true) }
    }

    @objc private func showDeleteHistory() {
        AppCoordinator.shared.showDeleteHistory()
    }

    // MARK: - Main menu

    /// Build a minimal programmatic main menu (no XIB). The App and Edit menus
    /// are required for ⌘Q / ⌘, and for text-field editing to work.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appName = AppInfo.displayName

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (so NSSearchField / text editing get the standard commands)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        // ⌘W routes through the responder chain to the key window's performClose:
        // (no menu item = no ⌘W). Lets the user close the main window from keyboard.
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let historyItem = NSMenuItem(title: "Delete History…", action: #selector(showDeleteHistory), keyEquivalent: "")
        historyItem.target = self
        windowMenu.addItem(historyItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Trash Sentinel notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show the banner even when BetterCleaner is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // Clicking a leftover-cleanup notification brings the main window forward.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            AppCoordinator.shared.showMainWindow()
        }
        completionHandler()
    }
}
