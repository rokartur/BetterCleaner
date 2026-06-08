import AppKit

/// Owns the single main window and routes cross-cutting actions (shortcuts,
/// deep links, menu items) to it without those callers reaching into AppKit.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    private var mainWindowController: MainWindowController?

    private init() {}

    @discardableResult
    func mainController() -> MainWindowController {
        if let existing = mainWindowController { return existing }
        let controller = MainWindowController()
        mainWindowController = controller
        return controller
    }

    func showMainWindow() {
        let controller = mainController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshApps() {
        showMainWindow()
        mainController().refreshApps()
    }

    func showOrphaned() {
        showMainWindow()
        mainController().showOrphanedMode()
    }

    func uninstall(name: String?, path: String?, matchType: String?) {
        showMainWindow()
        mainController().selectApp(name: name, path: path)
    }

    func showDeleteHistory() {
        showMainWindow()
        mainController().showDeleteHistory()
    }
}
