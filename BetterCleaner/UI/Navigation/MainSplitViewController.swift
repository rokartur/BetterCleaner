import AppKit

struct PageHistory: Equatable {
    private(set) var current: String
    private var back: [String] = []
    private var forward: [String] = []

    init(initial: String) { current = initial }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func visit(_ page: String) {
        guard page != current else { return }
        back.append(current)
        current = page
        forward.removeAll()
    }

    mutating func goBack() -> String? {
        guard let page = back.popLast() else { return nil }
        forward.append(current)
        current = page
        return page
    }

    mutating func goForward() -> String? {
        guard let page = forward.popLast() else { return nil }
        back.append(current)
        current = page
        return page
    }
}

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
    private lazy var homebrewAutomationVC = HomebrewAutomationViewController()
    private lazy var homebrewMaintenanceVC = HomebrewMaintenanceViewController()
    private lazy var developmentVC = DevelopmentViewController()
    private lazy var fileSearchVC = FileSearchViewController()
    private lazy var deleteHistoryVC = DeleteHistoryViewController()

    // App-uninstall scan state (absorbed from the old ApplicationsViewController).
    private var currentApp: InstalledApp?
    private var installedApps: [InstalledApp] = []
    private var scanGeneration = 0
    /// Cancels the in-flight leftover scan when the user selects another app.
    private var currentScanToken: ScanToken?

    private var reclaimable: [String: Int64] = [:]
    private var pageHistory = PageHistory(initial: "applications")
    private var currentPageID: String { pageHistory.current }
    private var lastBrewPageID = "brew.installed"
    var onNavigationStateChanged: ((Bool, Bool) -> Void)? {
        didSet { notifyNavigationState() }
    }

    /// Pages that show the collapsible left sidebar (a master list in it). Every
    /// other page collapses the sidebar and takes the content area full-width.
    private static let sidebarPageIDs: Set<String> = ["applications", "pkg", "brew.installed", "brew.available", "brew.services", "brew.taps"]
    /// The four Homebrew categories, which share a single sidebar row and switch
    /// inside the list column.
    private static let brewCategoryPageIDs: Set<String> = ["brew.installed", "brew.available", "brew.services", "brew.taps"]
    private let hadSavedSplitLayout = UserDefaults.standard.object(
        forKey: "NSSplitView Subview Frames BetterCleanerMainSplit"
    ) != nil
    private var didApplyInitialSplitLayout = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Remember the user's split widths across launches.
        splitView.autosaveName = "BetterCleanerMainSplit"

        // Column 1 — the navigation sidebar (grouped page tabs). A
        // real sidebar item → automatic vibrancy + the traffic lights float over it
        // (System Settings look). Always visible: it's the only navigation, so it
        // can't be collapsed.
        navItem = NSSplitViewItem(sidebarWithViewController: navVC)
        // Fits the required 880pt minimum while preserving room for a page label
        // and its reclaimable-size badge at the normal 1040pt window size.
        navItem.minimumThickness = 200
        navItem.maximumThickness = 280
        navItem.canCollapse = false
        addSplitViewItem(navItem)

        // Column 2 — the master list (app list / package receipts) as a content-list
        // column, shown only on the Applications + Packages pages and collapsed
        // everywhere else.
        contentListItem = NSSplitViewItem(contentListWithViewController: sidebarContainer)
        contentListItem.minimumThickness = 280
        contentListItem.maximumThickness = 560
        // The master list is the only way to pick an app/package on its pages, so
        // the user must not be able to drag it closed. Pages without a master list
        // still collapse it programmatically via `isCollapsed`, which ignores this.
        contentListItem.canCollapse = false
        addSplitViewItem(contentListItem)

        // Column 3 — the detail content, swapped per page. Its minimum is the
        // remainder of the 880pt window minimum (Metrics.minWindow) after the
        // sidebar (200) and master-list (280) minimums and the split dividers.
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 391
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

    override func viewDidAppear() {
        super.viewDidAppear()
        // The first select(_:) runs before the window exists; reapply its title.
        view.window?.title = Self.windowTitle(for: currentPageID)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hadSavedSplitLayout,
              !didApplyInitialSplitLayout,
              splitView.bounds.width >= Metrics.defaultWindow.width
        else { return }
        didApplyInitialSplitLayout = true
        splitView.setPosition(Metrics.sidebarDefaultWidth, ofDividerAt: 0)
        splitView.setPosition(
            Metrics.sidebarDefaultWidth + splitView.dividerThickness + Metrics.listColumnDefaultWidth,
            ofDividerAt: 1
        )
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
            } else if let app = self.currentApp {
                self.currentApp = nil
                self.applicationsFileListVC.uninstallContext = nil
                self.applicationsFileListVC.showCompletion(
                    title: "\(app.name) Uninstalled",
                    message: "The app and selected files were moved to the Trash. Restore them from Delete History."
                )
            } else {
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
        homebrewMaintenanceVC.onChanged = { [weak self] in self?.homebrewListVC.rescan() }
        homebrewListVC.onMaintenanceRequested = { [weak self] anchor in self?.presentHomebrewMaintenance(anchor) }
        // Category switches are page-level navigation too: record them without
        // reloading the category that HomebrewListViewController already selected.
        homebrewListVC.onCategoryChanged = { [weak self] category in
            self?.recordHomebrewCategory(category)
        }
    }

    /// The toolbar's window title mirrors the sidebar: one "Homebrew" row, so all
    /// four categories share it (the column's switcher already names the category).
    private static func windowTitle(for id: String) -> String {
        if brewCategoryPageIDs.contains(id) { return "Homebrew" }
        return NavCatalog.section(id: id)?.title ?? "BetterCleaner"
    }

    private static func pageID(for category: HomebrewCategory) -> String {
        switch category {
        case .installed: return "brew.installed"
        case .available: return "brew.available"
        case .services:  return "brew.services"
        case .taps:      return "brew.taps"
        }
    }

    private func presentHomebrewMaintenance(_ anchor: NSButton) {
        HomebrewMaintenanceMenu.present(
            from: anchor,
            presenter: self,
            onOpenPage: { [weak self] id in self?.select(id) },
            onChanged: { [weak self] in self?.homebrewListVC.rescan() }
        )
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
            // Reading every receipt BOM here means the first scan does not pay for it.
            PackageOwnership.prewarm()
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
        guard FullDiskAccess.refresh() else {
            applicationsFileListVC.showFullDiskAccessRequired()
            return
        }
        applicationsFileListVC.showLoading("Scanning \(app.name)…", title: app.name, determinate: true)

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
        let extraRoots = Preferences.shared.extraScanURLs
        let excluded = ScanExclusions.set(from: Preferences.shared.orphanExclusionURLs)
        let conditions = Preferences.shared.enabledConditions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The Finder extension deep-links straight into a scan, which on a cold
            // launch happens before the first app refresh lands. Suite-package
            // safety is derived from this inventory, so an empty one gets filled in
            // rather than scanned around.
            let inventory = otherApps.isEmpty ? AppFinder.installedApps(extraRoots: extraRoots) : otherApps
            let items = LeftoverScanner.scan(
                app: app,
                sensitivity: sensitivity,
                includeSystem: includeSystem,
                otherApps: inventory,
                excluded: excluded,
                conditions: conditions,
                isCancelled: { token.isCancelled }
            ) { fraction in
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
                self.applicationsFileListVC.showResults(
                    sections,
                    title: app.name,
                    subtitle: Self.heroSubtitle(app: app, count: items.count),
                    metric: FileSize.string(total),
                    detail: app.bundleID ?? ""
                )
            }
        }
    }

    /// "vVersion · N items · " — the hero header's summary lead-in. The size is
    /// passed separately so it can carry the emphasis, and the bundle id drops to
    /// the footnote line: it identifies the app but is never what the user decides on.
    private static func heroSubtitle(app: InstalledApp, count: Int) -> String {
        var parts: [String] = []
        if let version = app.shortVersion, !version.isEmpty { parts.append("v\(version)") }
        parts.append("\(count) item\(count == 1 ? "" : "s")")
        return parts.joined(separator: " · ") + " · "
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
        // The catalog decides what is routable, so a new row needs no second list.
        let requested = NavCatalog.section(id: id) != nil ? id : "applications"
        // The one Homebrew sidebar row reopens the category used most recently.
        let resolved = requested == "brew.installed" ? lastBrewPageID : requested
        pageHistory.visit(resolved)
        showPage(resolved)
    }

    func goBack() {
        guard let page = pageHistory.goBack() else { return }
        showPage(page)
    }

    func goForward() {
        guard let page = pageHistory.goForward() else { return }
        showPage(page)
    }

    private func recordHomebrewCategory(_ category: HomebrewCategory) {
        let page = Self.pageID(for: category)
        lastBrewPageID = page
        pageHistory.visit(page)
        view.window?.title = Self.windowTitle(for: page)
        notifyNavigationState()
    }

    private func showPage(_ page: String) {
        if Self.brewCategoryPageIDs.contains(page) { lastBrewPageID = page }
        view.window?.title = Self.windowTitle(for: page)
        // Every brew category shares one sidebar row, so highlight that row for all
        // of them instead of clearing the selection on a category the list owns.
        navVC.selectRow(Self.brewCategoryPageIDs.contains(page) ? "brew.installed" : page)
        setContentListCollapsed(!Self.sidebarPageIDs.contains(page))
        switch page {
        case "junk":
            container.setContent(cleanupVC); cleanupVC.startIfNeeded()
        case "orphaned":
            container.setContent(orphanedVC); orphanedVC.startIfNeeded()
        case "pkg":
            sidebarContainer.setContent(packageListVC)
            container.setContent(packageDetailVC)
            packageListVC.startIfNeeded()
        case "brew.installed", "brew.available", "brew.services", "brew.taps":
            let category: HomebrewCategory = page == "brew.services" ? .services
                : (page == "brew.taps" ? .taps
                   : (page == "brew.available" ? .available : .installed))
            sidebarContainer.setContent(homebrewListVC)
            container.setContent(homebrewDetailVC)
            homebrewListVC.setCategory(category)
        case "brew.autoupdate":
            container.setContent(homebrewAutomationVC)
        case "brew.maintenance":
            container.setContent(homebrewMaintenanceVC); homebrewMaintenanceVC.startIfNeeded()
        case "devenv":
            container.setContent(developmentVC); developmentVC.startIfNeeded()
        case "search":
            container.setContent(fileSearchVC)
        case "history":
            container.setContent(deleteHistoryVC); deleteHistoryVC.reload()
        default:
            sidebarContainer.setContent(appListVC)
            container.setContent(applicationsFileListVC)
            if currentApp == nil {
                if FullDiskAccess.refresh() {
                    applicationsFileListVC.showPlaceholder("Select an app to see the files it left behind.")
                } else {
                    applicationsFileListVC.showFullDiskAccessRequired()
                }
            }
        }
        notifyNavigationState()
    }

    private func notifyNavigationState() {
        onNavigationStateChanged?(pageHistory.canGoBack, pageHistory.canGoForward)
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
