import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    private let splitVC = MainSplitViewController()
    private lazy var rootVC = RootViewController(split: splitVC)
    private var didInitialScan = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            // .fullSizeContentView + transparent titlebar lets the sidebar run full
            // height with the traffic lights floating over it (System Settings look).
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterCleaner"
        window.titleVisibility = .hidden
        // Opaque titlebar (like BetterSettings) so the unified toolbar centers the
        // traffic lights in the taller band — they sit lower, matching BetterSettings.
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        // Drag the window from any non-interactive background area (sidebar empty
        // space, detail backgrounds).
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 880, height: 500)
        super.init(window: window)

        // An empty unified toolbar (no items) — its only job is to give the titlebar
        // the taller unified height so the traffic lights sit lower, exactly like the
        // BetterSettings window. Navigation + Settings still live in the sidebar.
        let toolbar = NSToolbar(identifier: "BetterCleanerMainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Page navigation and Settings both live in the split's source-list sidebar;
        // the window controller just hosts the split.
        window.contentViewController = rootVC
        window.setFrameAutosaveName("BetterCleanerMainWindow")
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

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
