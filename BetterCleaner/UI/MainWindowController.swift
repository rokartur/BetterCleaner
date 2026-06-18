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
            // There is no toolbar — navigation and Settings both live in the sidebar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BetterCleaner"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Drag the window from any non-interactive background area (sidebar empty
        // space, detail backgrounds) — there's no toolbar to grab anymore.
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 880, height: 500)
        super.init(window: window)

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
