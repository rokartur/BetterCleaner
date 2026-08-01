import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private static let navigationItemIdentifier = NSToolbarItem.Identifier("BetterCleanerNavigation")

    private let splitVC = MainSplitViewController()
    private lazy var rootVC = RootViewController(split: splitVC)
    private lazy var navigationControl: NSSegmentedControl = {
        let back = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!
        let forward = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!
        let control = NSSegmentedControl(
            images: [back, forward],
            trackingMode: .momentary,
            target: self,
            action: #selector(navigateHistory(_:))
        )
        control.segmentStyle = .texturedRounded
        control.setWidth(34, forSegment: 0)
        control.setWidth(34, forSegment: 1)
        control.setToolTip("Back", forSegment: 0)
        control.setToolTip("Forward", forSegment: 1)
        control.setAccessibilityLabel("Navigation history")
        control.setAccessibilityHelp("Go back or forward through visited pages.")
        control.setEnabled(false, forSegment: 0)
        control.setEnabled(false, forSegment: 1)
        return control
    }()
    private lazy var navigationItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: Self.navigationItemIdentifier)
        item.label = "Navigation"
        item.paletteLabel = "Navigation"
        item.toolTip = "Back and Forward"
        item.view = navigationControl
        item.isNavigational = true
        return item
    }()
    private var didInitialScan = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.defaultWindow),
            // .fullSizeContentView + transparent titlebar lets the sidebar run full
            // height with the traffic lights floating over it (System Settings look).
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The toolbar shows the current page as the window title (Finder-style);
        // MainSplitViewController updates it on every page change.
        window.title = "BetterCleaner"
        // Opaque titlebar (like BetterSettings) so the unified toolbar centers the
        // traffic lights in the taller band — they sit lower, matching BetterSettings.
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        // Drag the window from any non-interactive background area (sidebar empty
        // space, detail backgrounds).
        window.isMovableByWindowBackground = true
        super.init(window: window)

        // Match System Settings: page navigation lives in the unified titlebar,
        // while primary destinations remain in the sidebar.
        let toolbar = NSToolbar(identifier: "BetterCleanerMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        splitVC.onNavigationStateChanged = { [weak self] canGoBack, canGoForward in
            self?.navigationControl.setEnabled(canGoBack, forSegment: 0)
            self?.navigationControl.setEnabled(canGoForward, forSegment: 1)
        }

        // Assigning a split content controller can size the window down to the
        // panes' minimums. Reassert the product default before restoring any saved
        // user frame, while still allowing the 880×500 minimum afterward.
        window.contentViewController = rootVC
        window.setContentSize(Metrics.defaultWindow)
        window.minSize = Metrics.minWindow
        window.setFrameAutosaveName("BetterCleanerMainWindow")
        // Center only when no frame was saved yet (first launch); an
        // unconditional center() here would discard the restored position.
        if !window.setFrameUsingName("BetterCleanerMainWindow") {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func navigateHistory(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { splitVC.goBack() }
        else if sender.selectedSegment == 1 { splitVC.goForward() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        scheduleInitialScan()
    }

    /// One calm background pass shortly after launch fills the page-menu sizes,
    /// so the app shows "what's worth cleaning" without a dashboard.
    /// Gated on Full Disk Access — without it the scanners read partial data and
    /// would show wrong-low numbers; sizes stay blank until the pass runs.
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
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationItemIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == Self.navigationItemIdentifier ? navigationItem : nil
    }
}
