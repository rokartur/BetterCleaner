import Cocoa
import FinderSync

/// Finder extension: adds "Uninstall with BetterCleaner" to the right-click menu
/// for a single `.app` selection, deep-linking back into the main app.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Observe the apps folders so the context menu is offered there.
        let apps = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        FIFinderSyncController.default().directoryURLs = Set(apps)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard selected.count == 1, selected[0].pathExtension == "app" else { return nil }

        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Uninstall with BetterCleaner", action: #selector(uninstall(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc private func uninstall(_ sender: AnyObject?) {
        guard let url = FIFinderSyncController.default().selectedItemURLs()?.first else { return }
        var components = URLComponents()
        components.scheme = "bettercleaner"
        components.host = "uninstallApp"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let deepLink = components.url {
            NSWorkspace.shared.open(deepLink)
        }
    }
}
