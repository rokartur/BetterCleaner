import AppKit

/// Root split: the installed-apps list as a collapsible **sidebar** (shown on the
/// Applications page, hidden on every other page) plus a content area that swaps
/// per the page chosen from the toolbar's page menu.
///
/// Owns the app-uninstall scan orchestration that used to live in the now-deleted
/// `ApplicationsViewController` — the app list and its per-app file detail were
/// split apart (list → sidebar, detail → content), so the single owner of both
/// halves is this controller.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    /// The primary navigation: a native source-list sidebar of grouped page tabs.
    /// It drives `select(_:)`; programmatic page changes mirror back onto it.
    private let navVC = NavSidebarViewController()
    private var navItem: NSSplitViewItem!

    private let appListVC = AppListViewController()
    /// The middle column hosts a swappable master list: the app list (Applications)
    /// or the package receipt list (Packages). Both pages share the one collapsible
    /// content-list column; every other page collapses it.
    private let sidebarContainer = ContainerViewController()
    private let container = ContainerViewController()
    private var contentListItem: NSSplitViewItem!

    /// The Applications page's detail pane (per-app leftover files + Uninstall).
    private let applicationsFileListVC = FileListViewController()

    private lazy var cleanupVC = CleanupViewController()
    private lazy var orphanedVC = OrphanedViewController()
    /// Packages page halves — list lives in the shared sidebar, detail in content.
    private lazy var packageListVC = PackageListViewController()
    private lazy var packageDetailVC = PackageDetailViewController()
    /// Homebrew page halves — list (Installed/Services/Taps) in the shared sidebar,
    /// detail in content. Coordinates search & maintenance sheets.
    private lazy var homebrewListVC = HomebrewListViewController()
    private lazy var homebrewDetailVC = HomebrewDetailViewController()
    private lazy var developmentVC = DevelopmentViewController()
    private lazy var deleteHistoryVC = DeleteHistoryViewController()

    // App-uninstall scan state (absorbed from the old ApplicationsViewController).
    private var currentApp: InstalledApp?
    private var installedApps: [InstalledApp] = []
    private var scanGeneration = 0
    /// Cancels the in-flight leftover scan when the user selects another app.
    private var currentScanToken: ScanToken?

    private var reclaimable: [String: Int64] = [:]

    /// Every selectable page other than the default Applications page.
    private static let pageIDs: Set<String> = ["junk", "orphaned", "pkg", "homebrew", "devenv", "history"]
    /// Pages that show the collapsible left sidebar (a master list in it). Every
    /// other page collapses the sidebar and takes the content area full-width.
    private static let sidebarPageIDs: Set<String> = ["applications", "pkg", "homebrew"]

    override func viewDidLoad() {
        super.viewDidLoad()

        // Remember the user's split widths across launches.
        splitView.autosaveName = "BetterCleanerMainSplit"

        // Column 1 — the navigation sidebar (grouped page tabs + Settings footer). A
        // real sidebar item → automatic vibrancy + the traffic lights float over it
        // (System Settings look). Always visible: it's the only navigation, so it
        // can't be collapsed.
        navItem = NSSplitViewItem(sidebarWithViewController: navVC)
        // 220 floor so a page label + its reclaimable-size badge both fit without
        // truncating the title (e.g. "System Junk   30.64 GB").
        navItem.minimumThickness = 220
        navItem.maximumThickness = 280
        navItem.canCollapse = false
        addSplitViewItem(navItem)

        // Column 2 — the master list (app list / package receipts) as a content-list
        // column, shown only on the Applications + Packages pages and collapsed
        // everywhere else.
        contentListItem = NSSplitViewItem(contentListWithViewController: sidebarContainer)
        contentListItem.minimumThickness = 240
        contentListItem.maximumThickness = 420
        contentListItem.canCollapse = true
        addSplitViewItem(contentListItem)

        // Column 3 — the detail content, swapped per page.
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 420
        addSplitViewItem(contentItem)

        wireReclaimable()
        wireApplications()
        wirePackages()
        wireHomebrew()

        // Wire the nav's callbacks only after every column exists, so the first
        // programmatic page set can't re-enter `select(_:)` before the other split
        // items are in place.
        navVC.onSelect = { [weak self] id in self?.select(id) }
        select("applications")
        refreshApps()
    }

    // MARK: - Applications orchestration

    private func wireApplications() {
        appListVC.onSelect = { [weak self] app in self?.scan(app: app) }
        appListVC.onRefresh = { [weak self] in self?.refreshApps() }
        applicationsFileListVC.onRescanRequested = { [weak self] in
            guard let self else { return }
            // Decide by what's on disk, not which action ran: if the bundle is
            // still installed (e.g. only languages were pruned) refresh its
            // remaining leftovers; if it's gone (complete uninstall moved it to the
            // Trash) clear the pane instead of re-scanning a trashed bundle.
            if let app = self.currentApp, FileManager.default.fileExists(atPath: app.url.path) {
                self.scan(app: app)
            } else {
                self.currentApp = nil
                self.applicationsFileListVC.uninstallContext = nil
                self.applicationsFileListVC.showPlaceholder("Select an app to see the files it left behind.")
            }
            self.refreshApps()
        }
    }

    // MARK: - Packages orchestration

    private func wirePackages() {
        packageListVC.onSelect = { [weak self] receipt in self?.packageDetailVC.show(receipt) }
        packageDetailVC.onChanged = { [weak self] in self?.packageListVC.rescan() }
    }

    // MARK: - Homebrew orchestration

    private func wireHomebrew() {
        homebrewListVC.onSelect = { [weak self] selection in self?.homebrewDetailVC.show(selection) }
        homebrewDetailVC.onChanged = { [weak self] in self?.homebrewListVC.rescan() }
        homebrewListVC.onAddRequested = { [weak self] in self?.presentHomebrewSearch() }
        homebrewListVC.onMaintenanceRequested = { [weak self] anchor in self?.presentHomebrewMaintenance(anchor) }
    }

    private func presentHomebrewSearch() {
        let search = HomebrewSearchViewController { [weak self] in self?.homebrewListVC.rescan() }
        presentAsSheet(search)
    }

    private func presentHomebrewMaintenance(_ anchor: NSButton) {
        HomebrewMaintenanceMenu.present(from: anchor, presenter: self) { [weak self] in
            self?.homebrewListVC.rescan()
        }
    }

    func refreshApps() {
        let extra = Preferences.shared.extraScanURLs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppFinder.installedApps(extraRoots: extra)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installedApps = apps
                self.appListVC.reload(with: apps)
            }
        }
        if container.current === orphanedVC { orphanedVC.rescan() }
    }

    func searchApps(_ text: String) { appListVC.setFilter(text) }

    func selectApp(name: String?, path: String?) {
        // Bring the Applications page forward (uncollapses the sidebar + shows the
        // file detail) before resolving + scanning the requested app.
        select("applications")
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if let app = AppFinder.app(at: url) { scan(app: app); return }
        }
        guard let name, !name.isEmpty else { return }
        if let app = matchApp(name: name, in: installedApps) { scan(app: app); return }
        let extra = Preferences.shared.extraScanURLs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppFinder.installedApps(extraRoots: extra)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installedApps = apps
                self.appListVC.reload(with: apps)
                if let app = self.matchApp(name: name, in: apps) { self.scan(app: app) }
            }
        }
    }

    private func matchApp(name: String, in apps: [InstalledApp]) -> InstalledApp? {
        let normalized = FileMatcher.normalize(name)
        return apps.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                || FileMatcher.normalize($0.name) == normalized
                || ($0.bundleID?.caseInsensitiveCompare(name) == .orderedSame)
        }
    }

    private func scan(app: InstalledApp) {
        currentApp = app
        // Per-app uninstall: the destructive button runs the full AppRemover flow
        // (quit/unload/TCC/receipts/Keychain) and the header shows the app's icon.
        applicationsFileListVC.uninstallContext = app
        applicationsFileListVC.showLoading("Scanning \(app.name)…", determinate: true)

        scanGeneration += 1
        let generation = scanGeneration
        // Cancel the previous scan so a stale background walk/Spotlight sweep stops
        // instead of running to completion while the user clicks through the sidebar.
        currentScanToken?.cancel()
        let token = ScanToken()
        currentScanToken = token
        let sensitivity = Preferences.shared.searchSensitivity
        let includeSystem = Preferences.shared.includeSystemFiles
        let otherApps = installedApps
        let excluded = ScanExclusions.set(from: Preferences.shared.orphanExclusionURLs)
        let conditions = Preferences.shared.enabledConditions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = LeftoverScanner.scan(app: app, sensitivity: sensitivity, includeSystem: includeSystem, otherApps: otherApps, excluded: excluded, conditions: conditions, isCancelled: { token.isCancelled }) { fraction in
                DispatchQueue.main.async {
                    guard let self, generation == self.scanGeneration else { return }
                    self.applicationsFileListVC.updateProgress(fraction)
                }
            }
            let sections = LeftoverScanner.sections(from: items)
            let total = items.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                // Drop stale results if a newer scan started meanwhile.
                guard let self, generation == self.scanGeneration else { return }
                self.applicationsFileListVC.showResults(sections, title: app.name, subtitle: Self.heroSubtitle(app: app, count: items.count, bytes: total))
            }
        }
    }

    /// "bundleID · vVersion · N items · size" — the hero header's summary line.
    private static func heroSubtitle(app: InstalledApp, count: Int, bytes: Int64) -> String {
        var parts: [String] = []
        if let b = app.bundleID, !b.isEmpty { parts.append(b) }
        if let v = app.shortVersion, !v.isEmpty { parts.append("v\(v)") }
        parts.append("\(count) item\(count == 1 ? "" : "s") · \(FileSize.string(bytes))")
        return parts.joined(separator: " · ")
    }

    // MARK: - Reclaimable totals (toolbar page menu sizes + running total)

    /// Eagerly subscribes to the three reclaimable sections' per-scan totals so the
    /// page-menu sizes + toolbar total fill whether or not the user opens a section
    /// (the "Scan all" button + launch auto-pass drive them off-screen).
    private func wireReclaimable() {
        cleanupVC.onReclaimable = { [weak self] bytes in self?.setReclaimable(bytes, for: "junk") }
        orphanedVC.onReclaimable = { [weak self] bytes in self?.setReclaimable(bytes, for: "orphaned") }
        developmentVC.onReclaimable = { [weak self] bytes in self?.setReclaimable(bytes, for: "devenv") }
    }

    private func setReclaimable(_ bytes: Int64, for id: String) {
        reclaimable[id] = bytes
        navVC.setSize(id, bytes)
    }

    /// Scan every reclaimable section (Junk / Orphaned / Development) off-screen to
    /// fill the page-menu sizes without changing the visible page.
    /// `force` rescans even already-scanned sections; otherwise it's a one-time
    /// fill reusing cached scans.
    func scanAll(force: Bool) {
        if force {
            cleanupVC.rescan()
            orphanedVC.rescan()
            developmentVC.rescan()
        } else {
            cleanupVC.startIfNeeded()
            orphanedVC.startIfNeeded()
            developmentVC.startIfNeeded()
        }
    }

    // MARK: - Page routing

    func select(_ id: String) {
        let resolved = Self.pageIDs.contains(id) ? id : "applications"
        navVC.selectRow(resolved)
        setContentListCollapsed(!Self.sidebarPageIDs.contains(resolved))
        switch resolved {
        case "junk":
            container.setContent(cleanupVC); cleanupVC.startIfNeeded()
        case "orphaned":
            container.setContent(orphanedVC); orphanedVC.startIfNeeded()
        case "pkg":
            sidebarContainer.setContent(packageListVC)
            container.setContent(packageDetailVC)
            packageListVC.startIfNeeded()
        case "homebrew":
            sidebarContainer.setContent(homebrewListVC)
            container.setContent(homebrewDetailVC)
            homebrewListVC.startIfNeeded()
        case "devenv":
            container.setContent(developmentVC); developmentVC.startIfNeeded()
        case "history":
            container.setContent(deleteHistoryVC); deleteHistoryVC.reload()
        default:
            sidebarContainer.setContent(appListVC)
            container.setContent(applicationsFileListVC)
            if currentApp == nil {
                applicationsFileListVC.showPlaceholder("Select an app to see the files it left behind.")
            }
        }
    }

    /// Collapse/expand the middle master-list column. Set the property directly —
    /// the `animator()` proxy silently no-ops here on macOS 26, leaving the list
    /// visible on section pages. Guarded so a repeat selection of the current page
    /// never jitters the divider.
    private func setContentListCollapsed(_ collapsed: Bool) {
        guard contentListItem.isCollapsed != collapsed else { return }
        contentListItem.isCollapsed = collapsed
    }

    // MARK: - Passthroughs (AppCoordinator / toolbar)

    func showOrphaned() { select("orphaned") }
    func showDeleteHistory() { select("history") }
}
