import AppKit

/// Master column for the Homebrew pages. Shows one category at a time — chosen by the
/// Homebrew sidebar rows (Installed / Services / Taps) via `setCategory(_:)`.
///
/// The Installed list is filterable (All / Formulae / Casks, and whether to include
/// dependencies) and grouped **Casks first, then Formulae** with section headers,
/// styled after TapHouse. Selecting a row drives the detail pane via `onSelect`.
@MainActor
final class HomebrewListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((HomebrewSelection?) -> Void)?
    var onAddRequested: (() -> Void)?
    var onMaintenanceRequested: ((NSButton) -> Void)?

    private var category: HomebrewCategory = .installed
    private var loaded: Set<HomebrewCategory> = []

    private var packages: [HomebrewPackage] = []
    private var services: [ServiceInfo] = []
    private var taps: [TapInfo] = []

    // Installed is grouped; services/taps stay flat.
    private enum InstalledRow { case header(String); case pkg(HomebrewPackage) }
    private var installedRows: [InstalledRow] = []
    private var filteredServices: [ServiceInfo] = []
    private var filteredTaps: [TapInfo] = []

    private var filterText = ""

    // Installed filters.
    private enum KindFilter { case all, formulae, casks }
    private var kindFilter: KindFilter = .all
    private var includeDependencies = true

    private let searchField = NSSearchField()
    private let filterButton = NSButton()
    private let addButton = NSButton()
    private let maintenanceButton = NSButton()
    private let refreshButton = NSButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "cup.and.saucer")

    // MARK: - Layout

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .contentBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        searchField.placeholderString = "Search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureToolButton(filterButton, symbol: "line.3.horizontal.decrease.circle", tip: "Filter", action: #selector(filterTapped))
        configureToolButton(addButton, symbol: "plus", tip: "Search & install a package", action: #selector(addTapped))
        configureToolButton(maintenanceButton, symbol: "ellipsis.circle", tip: "Maintenance (update, cleanup, Brewfile…)", action: #selector(maintenanceTapped))
        configureToolButton(refreshButton, symbol: "arrow.clockwise", tip: "Refresh", action: #selector(refreshTapped))

        let actionsRow = NSStackView(views: [searchField, filterButton, addButton, maintenanceButton, refreshButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = Spacing.sm
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(actionsRow)

        let column = NSTableColumn(identifier: HomebrewRowCell.identifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.rowHeight = 60
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        container.addSubview(scrollView)

        emptyState.isHidden = true
        container.addSubview(emptyState)
        container.addSubview(loadingView)

        NSLayoutConstraint.activate([
            actionsRow.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.sm),
            actionsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.sm),
            actionsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Spacing.sm),

            scrollView.topAnchor.constraint(equalTo: actionsRow.bottomAnchor, constant: Spacing.sm),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    private func configureToolButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Loading

    func setCategory(_ c: HomebrewCategory) {
        category = c
        searchField.stringValue = ""
        filterText = ""
        updateToolbarVisibility()
        onSelect?(nil)
        load(c, force: false)
    }

    func startIfNeeded() {
        updateToolbarVisibility()
        load(category, force: false)
    }

    private func updateToolbarVisibility() {
        let installed = category == .installed
        addButton.isHidden = !installed     // "install new" — Installed only
        filterButton.isHidden = !installed  // kind/deps filter — Installed only
    }

    func rescan() {
        loaded.removeAll()
        load(category, force: true)
    }

    private func load(_ target: HomebrewCategory, force: Bool) {
        guard HomebrewEnvironment.isInstalled else { showNotInstalled(); return }

        if loaded.contains(target) && !force {
            applyFilter()
            return
        }

        emptyState.isHidden = true
        loadingView.startIndeterminate("Loading \(target.title.lowercased())…")
        onSelect?(nil)
        installedRows = []; filteredServices = []; filteredTaps = []
        tableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pkgs: [HomebrewPackage]
            let svcs: [ServiceInfo]
            let taps: [TapInfo]
            switch target {
            case .installed: pkgs = HomebrewService.installedPackages(); svcs = []; taps = []
            case .services:  pkgs = [];                                   svcs = HomebrewService.services(); taps = []
            case .taps:      pkgs = [];                                   svcs = [];  taps = HomebrewService.taps()
            }
            DispatchQueue.main.async {
                guard let self, self.category == target else { return }
                self.loadingView.stop()
                switch target {
                case .installed: self.packages = pkgs
                case .services:  self.services = svcs
                case .taps:      self.taps = taps
                }
                self.loaded.insert(target)
                self.applyFilter()
            }
        }
    }

    private func showNotInstalled() {
        loadingView.stop()
        packages = []; services = []; taps = []
        applyFilter()
        emptyState.isHidden = false
        emptyState.configure(
            symbol: "cup.and.saucer",
            title: "Homebrew isn't installed",
            message: "Install Homebrew to manage formulae, casks, services and taps from here.",
            actionTitle: "Install Homebrew…",
            action: { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
        )
    }

    // MARK: - Filtering

    @objc private func searchChanged() {
        filterText = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    private func applyFilter() {
        let q = filterText
        filteredServices = q.isEmpty ? services : services.filter { $0.name.localizedCaseInsensitiveContains(q) }
        filteredTaps = q.isEmpty ? taps : taps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        installedRows = buildInstalledRows(query: q)
        updateEmptyState()
        tableView.reloadData()
    }

    /// Filter by kind + dependency, then group Casks first, Formulae second.
    private func buildInstalledRows(query q: String) -> [InstalledRow] {
        var pkgs = packages
        switch kindFilter {
        case .all:      break
        case .formulae: pkgs = pkgs.filter { !$0.isCask }
        case .casks:    pkgs = pkgs.filter { $0.isCask }
        }
        if !includeDependencies {
            // Casks are always installed on request; only prune dependency formulae.
            pkgs = pkgs.filter { $0.isCask || $0.installedOnRequest }
        }
        if !q.isEmpty {
            pkgs = pkgs.filter {
                $0.displayName.localizedCaseInsensitiveContains(q)
                    || $0.token.localizedCaseInsensitiveContains(q)
                    || $0.description.localizedCaseInsensitiveContains(q)
            }
        }
        let casks = pkgs.filter { $0.isCask }
        let formulae = pkgs.filter { !$0.isCask }
        let showHeaders = (kindFilter == .all)

        var rows: [InstalledRow] = []
        if !casks.isEmpty {
            if showHeaders { rows.append(.header("Casks  \(casks.count)")) }
            rows += casks.map { .pkg($0) }
        }
        if !formulae.isEmpty {
            if showHeaders { rows.append(.header("Formulae  \(formulae.count)")) }
            rows += formulae.map { .pkg($0) }
        }
        return rows
    }

    private func updateEmptyState() {
        guard HomebrewEnvironment.isInstalled else { return }
        let count = rowCount
        let sourceEmpty: Bool
        switch category {
        case .installed: sourceEmpty = packages.isEmpty
        case .services:  sourceEmpty = services.isEmpty
        case .taps:      sourceEmpty = taps.isEmpty
        }
        emptyState.isHidden = count != 0
        if count == 0 {
            emptyState.configure(
                symbol: sourceEmpty ? "cup.and.saucer" : "magnifyingglass",
                title: sourceEmpty ? "No \(category.title.lowercased())" : "No matches",
                message: sourceEmpty ? emptyMessage(for: category) : ""
            )
        }
    }

    private func emptyMessage(for category: HomebrewCategory) -> String {
        switch category {
        case .installed: return "Nothing is installed via Homebrew yet."
        case .services:  return "No Homebrew services are configured."
        case .taps:      return "No third-party taps are added."
        }
    }

    // MARK: - Actions

    @objc private func refreshTapped() { load(category, force: true) }
    @objc private func addTapped() { onAddRequested?() }
    @objc private func maintenanceTapped() { onMaintenanceRequested?(maintenanceButton) }

    @objc private func filterTapped() {
        let menu = NSMenu()
        func add(_ title: String, _ on: Bool, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("All", kindFilter == .all, #selector(filterAll))
        add("Formulae only", kindFilter == .formulae, #selector(filterFormulae))
        add("Casks only", kindFilter == .casks, #selector(filterCasks))
        menu.addItem(.separator())
        add("Include dependencies", includeDependencies, #selector(toggleDependencies))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.height + 4), in: filterButton)
    }

    @objc private func filterAll()      { kindFilter = .all; applyFilter() }
    @objc private func filterFormulae() { kindFilter = .formulae; applyFilter() }
    @objc private func filterCasks()    { kindFilter = .casks; applyFilter() }
    @objc private func toggleDependencies() { includeDependencies.toggle(); applyFilter() }

    // MARK: - Table

    private var rowCount: Int {
        switch category {
        case .installed: return installedRows.count
        case .services:  return filteredServices.count
        case .taps:      return filteredTaps.count
        }
    }

    private func isHeader(_ row: Int) -> Bool {
        guard category == .installed, row >= 0, row < installedRows.count else { return false }
        if case .header = installedRows[row] { return true }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if category == .installed, case .header(let title) = installedRows[row] {
            let cell = tableView.makeView(withIdentifier: HomebrewHeaderCell.identifier, owner: self) as? HomebrewHeaderCell ?? HomebrewHeaderCell()
            cell.configure(title)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: HomebrewRowCell.identifier, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        switch category {
        case .installed:
            if case .pkg(let p) = installedRows[row] { cell.configure(model(for: p)) }
        case .services:  cell.configure(model(for: filteredServices[row]))
        case .taps:      cell.configure(model(for: filteredTaps[row]))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        isHeader(row) ? nil : HomebrewRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeader(row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { isHeader(row) ? 30 : 60 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeader(row) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rowCount else { onSelect?(nil); return }
        switch category {
        case .installed:
            if case .pkg(let p) = installedRows[row] { onSelect?(.package(p)) } else { onSelect?(nil) }
        case .services:  onSelect?(.service(filteredServices[row]))
        case .taps:      onSelect?(.tap(filteredTaps[row]))
        }
    }

    // MARK: - Row models (TapHouse-style tile + pills + version)

    private func model(for p: HomebrewPackage) -> HomebrewRowModel {
        let leading: HomebrewRowModel.Leading
        var pills: [PillSpec] = []
        if p.isCask {
            let appPath = "/Applications/\(p.displayName).app"
            if FileManager.default.fileExists(atPath: appPath) {
                leading = .appIcon(NSWorkspace.shared.icon(forFile: appPath))
            } else {
                leading = .glyph(symbol: "macwindow", color: .systemGray)
            }
            if let source = caskSourcePill(p) { pills.append(source) }
        } else {
            leading = .glyph(symbol: "terminal", color: .systemGreen)
            if !p.installedOnRequest { pills.append(PillSpec(text: "dep", color: nil)) }
            pills.append(PillSpec(text: "brew", color: .systemOrange))
        }
        if p.isPinned { pills.append(PillSpec(text: "Pinned", color: nil)) }
        return HomebrewRowModel(
            leading: leading, title: p.displayName, pills: pills,
            subtitle: p.description, version: p.installedVersion,
            updateAvailable: p.isOutdated)
    }

    /// The cask's source as a pill: a purple "GitHub" for GitHub-hosted casks,
    /// otherwise the homepage domain in a neutral tag.
    private func caskSourcePill(_ p: HomebrewPackage) -> PillSpec? {
        guard var host = URL(string: p.homepage)?.host else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if host.contains("github.com") || host.contains("github.io") {
            return PillSpec(text: "GitHub", color: .systemPurple)
        }
        return PillSpec(text: host, color: nil)
    }

    private func model(for s: ServiceInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "gearshape.2", color: s.isRunning ? .systemGreen : .systemGray),
            title: s.name,
            pills: s.isRunning ? [PillSpec(text: "Running", color: .systemGreen)] : [PillSpec(text: "Stopped", color: nil)],
            subtitle: s.user.map { "User: \($0)" } ?? "")
    }

    private func model(for t: TapInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "arrow.triangle.branch", color: .systemBlue),
            title: t.name,
            pills: (t.official ?? false) ? [PillSpec(text: "Official", color: .systemBlue)] : [],
            subtitle: "\(t.packageCount) package\(t.packageCount == 1 ? "" : "s")")
    }
}
