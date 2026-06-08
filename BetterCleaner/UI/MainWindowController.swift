import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let splitVC = MainSplitViewController()
    private lazy var rootVC = RootViewController(split: splitVC)
    private var didInitialScan = false

    /// The toolbar page menu — its face shows the current page; the dropdown lists
    /// every page (with a reclaimable size next to the scannable ones).
    private let pagePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Toolbar running total of reclaimable space; "—" until the first scan reports.
    private let totalField = NSTextField(labelWithString: "—")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            // .fullSizeContentView lets the app-list sidebar run full height with
            // the traffic lights floating over it (System Settings look). The
            // sidebar stays collapsible via the toolbar's toggle button.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterCleaner"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 880, height: 500)
        super.init(window: window)

        totalField.font = Typography.monospacedDigit(.subheadline, weight: .semibold)
        totalField.textColor = .secondaryLabelColor
        totalField.toolTip = "Reclaimable space found by the last scan"

        buildPagePopup()

        // Wire the split's callbacks BEFORE loading its view (setting
        // contentViewController runs viewDidLoad, which fires the first
        // `onSectionChanged` for the default Applications page).
        splitVC.onTotalChanged = { [weak self] bytes in
            self?.totalField.stringValue = bytes > 0 ? FileSize.string(bytes) : "—"
        }
        splitVC.onSectionChanged = { [weak self] id in
            self?.selectPopup(id)
            // The sidebar toggle only makes sense on the pages that show the
            // collapsible sidebar (Applications + Packages); hide it elsewhere.
            self?.setSidebarToggleVisible(id == "applications" || id == "pkg")
        }
        splitVC.onSectionSizeChanged = { [weak self] id, bytes in self?.setSectionSize(id, bytes) }

        window.contentViewController = rootVC
        window.setFrameAutosaveName("BetterCleanerMainWindow")
        window.center()

        setupToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        scheduleInitialScan()
    }

    /// One calm background pass shortly after launch fills the page-menu sizes +
    /// toolbar total, so the app shows "what's worth cleaning" without a dashboard.
    /// Gated on Full Disk Access — without it the scanners read partial data and
    /// would show wrong-low numbers; sizes stay blank until "Scan all".
    private func scheduleInitialScan() {
        guard !didInitialScan else { return }
        didInitialScan = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, FullDiskAccess.isGranted else { return }
            self.splitVC.scanAll(force: false)
        }
    }

    // MARK: - Actions (driven by AppCoordinator)

    func refreshApps() { splitVC.refreshApps() }
    func showOrphanedMode() { splitVC.showOrphaned() }
    func showDeleteHistory() { splitVC.showDeleteHistory() }
    func selectApp(name: String?, path: String?) { splitVC.selectApp(name: name, path: path) }

    // MARK: - Page menu

    private func buildPagePopup() {
        pagePopup.translatesAutoresizingMaskIntoConstraints = false
        pagePopup.target = self
        pagePopup.action = #selector(pageChanged)
        let menu = NSMenu()
        let sizeCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        for section in NavCatalog.all where section.enabled {
            let item = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            item.representedObject = section.id
            // A plain tinted SF Symbol (no gradient tile) — native + flat.
            let colorCfg = NSImage.SymbolConfiguration(paletteColors: [section.tint])
            let image = NSImage(systemSymbolName: section.icon, accessibilityDescription: section.title)?
                .withSymbolConfiguration(sizeCfg.applying(colorCfg))
            image?.isTemplate = false
            item.image = image
            menu.addItem(item)
        }
        pagePopup.menu = menu
        // Keep a stable width so the custom-view toolbar item doesn't collapse.
        pagePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    @objc private func pageChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        splitVC.select(id)
    }

    /// Mirror a programmatic page change on the menu face. `select(_:)` on
    /// `NSPopUpButton` does not re-fire the action, so there's no feedback loop.
    private func selectPopup(_ id: String) {
        guard let item = pagePopup.menu?.items.first(where: { $0.representedObject as? String == id }) else { return }
        pagePopup.select(item)
    }

    /// Append a reclaimable size to a page's menu item (e.g. "System Junk  4.2 GB").
    private func setSectionSize(_ id: String, _ bytes: Int64) {
        guard let section = NavCatalog.section(id: id),
              let item = pagePopup.menu?.items.first(where: { $0.representedObject as? String == id }) else { return }
        item.title = bytes > 0 ? "\(section.title)   \(FileSize.string(bytes))" : section.title
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let page = NSToolbarItem.Identifier("page")
        static let scanAll = NSToolbarItem.Identifier("scanAll")
        static let total = NSToolbarItem.Identifier("reclaimableTotal")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "BetterCleanerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) { window?.toolbarStyle = .unified }
    }

    /// Show/hide the `.toggleSidebar` toolbar item (always the first item) without
    /// rebuilding the toolbar. Pages without a sidebar shouldn't offer the toggle.
    private func setSidebarToggleVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let present = toolbar.items.first?.itemIdentifier == .toggleSidebar
        if visible, !present {
            toolbar.insertItem(withItemIdentifier: .toggleSidebar, at: 0)
        } else if !visible, present {
            toolbar.removeItem(at: 0)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // .toggleSidebar routes through the responder chain to
        // NSSplitViewController.toggleSidebar (collapses the app list). The page
        // menu sits beside it; the reclaimable total + "Scan all" + Settings on
        // the right.
        [.toggleSidebar, ToolbarID.page, .flexibleSpace, ToolbarID.total, ToolbarID.scanAll, ToolbarID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, ToolbarID.page, .flexibleSpace, .space, ToolbarID.total, ToolbarID.scanAll, ToolbarID.settings]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.page:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Page"
            item.toolTip = "Switch between tools"
            item.view = pagePopup
            item.visibilityPriority = .high
            return item

        case ToolbarID.scanAll:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Scan all"
            item.toolTip = "Scan every category for reclaimable space"
            item.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Scan all")
            item.target = self
            item.action = #selector(scanAllClicked)
            item.isBordered = true
            return item

        case ToolbarID.total:
            // Custom-view item so the number shows even though the toolbar is
            // displayMode .iconOnly (which would suppress a plain label item).
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reclaimable"
            item.view = totalField
            item.visibilityPriority = .high
            return item

        case ToolbarID.settings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.target = self
            item.action = #selector(settingsClicked)
            item.isBordered = true
            return item

        default:
            return nil
        }
    }

    @objc private func scanAllClicked() {
        splitVC.scanAll(force: true)
    }

    @objc private func settingsClicked() {
        SettingsWindowPresenter.shared.show()
    }
}
