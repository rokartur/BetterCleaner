import AppKit

/// Master column for the Homebrew page. Shows one category at a time — chosen by
/// the segmented switcher at the top of this column (Installed / Available /
/// Services / Taps), or programmatically via `setCategory(_:)`.
///
/// The Installed list is filterable (All / Formulae / Casks, and whether to include
/// dependencies) and grouped **Casks first, then Formulae** with section headers,
/// styled after TapHouse. Selecting a row drives the detail pane via `onSelect`.
@MainActor
final class HomebrewListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((HomebrewSelection?) -> Void)?
    var onMaintenanceRequested: ((NSButton) -> Void)?
    /// Fired when the user switches category here, so the owner can keep its page
    /// routing in step without the switcher and the router fighting each other.
    var onCategoryChanged: ((HomebrewCategory) -> Void)?

    private var category: HomebrewCategory = .installed
    private var loaded: Set<HomebrewCategory> = []

    private var packages: [HomebrewPackage] = []
    private var availablePackages: [HomebrewPackageRef] = []
    private var availableSearch: [HomebrewPackageRef: String] = [:]
    private var services: [ServiceInfo] = []
    private var taps: [TapInfo] = []

    private enum Row {
        case header(String)
        case package(HomebrewPackage)
        case reference(HomebrewPackageRef, description: String)
        case service(ServiceInfo)
        case tap(TapInfo)
    }
    private var rows: [Row] = []

    private var filterText = ""

    // Installed filters.
    private enum KindFilter { case all, formulae, casks }
    private var kindFilter: KindFilter = .all
    private var includeDependencies = true
    private var updatesOnly = false
    private var sortAscending = true
    private var searchGeneration = 0
    private var loadGeneration = 0

    private let categorySwitcher = NSSegmentedControl(
        labels: HomebrewCategory.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil
    )
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

        // The four Homebrew categories switch here rather than owning four sidebar
        // rows: they're views of one destination, and as sidebar rows they made
        // Homebrew half the app's navigation.
        categorySwitcher.translatesAutoresizingMaskIntoConstraints = false
        categorySwitcher.segmentDistribution = .fillEqually
        categorySwitcher.selectedSegment = 0
        categorySwitcher.target = self
        categorySwitcher.action = #selector(categorySwitched)
        categorySwitcher.setAccessibilityLabel("Homebrew category")

        searchField.placeholderString = "Search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureToolButton(filterButton, symbol: "line.3.horizontal.decrease.circle", tip: "Filter", action: #selector(filterTapped))
        configureToolButton(addButton, symbol: "plus", tip: "Add a tap", action: #selector(addTapped))
        configureToolButton(
            maintenanceButton,
            symbol: "ellipsis.circle",
            tip: "Homebrew actions: update, upgrade all, cleanup, and Brewfile",
            action: #selector(maintenanceTapped)
        )
        configureToolButton(refreshButton, symbol: "arrow.clockwise", tip: "Refresh", action: #selector(refreshTapped))

        let actionsRow = NSStackView(views: [searchField, filterButton, addButton, maintenanceButton, refreshButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = Spacing.sm
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(categorySwitcher)
        container.addSubview(actionsRow)

        let column = NSTableColumn(identifier: HomebrewRowCell.identifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.rowHeight = Metrics.rowHeight
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
            categorySwitcher.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.sm),
            categorySwitcher.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.sm),
            categorySwitcher.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Spacing.sm),

            actionsRow.topAnchor.constraint(equalTo: categorySwitcher.bottomAnchor, constant: Spacing.sm),
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
        button.setAccessibilityLabel(tip)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Loading

    func setCategory(_ newCategory: HomebrewCategory) {
        searchGeneration += 1
        loadGeneration += 1
        loadingView.stop()
        category = newCategory
        categorySwitcher.selectedSegment = newCategory.rawValue
        searchField.stringValue = ""
        filterText = ""
        updateToolbarVisibility()
        onSelect?(nil)
        load(newCategory, force: false)
    }

    @objc private func categorySwitched() {
        guard let picked = HomebrewCategory(rawValue: categorySwitcher.selectedSegment),
              picked != category
        else { return }
        setCategory(picked)
        onCategoryChanged?(picked)
    }

    func startIfNeeded() {
        updateToolbarVisibility()
        load(category, force: false)
    }

    private func updateToolbarVisibility() {
        addButton.isHidden = category != .taps
        filterButton.isHidden = category != .installed && category != .available
        searchField.placeholderString = "Search \(category.title.lowercased())"
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
        if target == .available { searchGeneration += 1 }
        loadGeneration += 1
        let generation = loadGeneration
        loadingView.startIndeterminate("Loading \(target.title.lowercased())…")
        tableView.deselectAll(nil)
        onSelect?(nil)
        rows = []
        tableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pkgs: [HomebrewPackage] = []
            var available: [HomebrewPackageRef] = []
            var svcs: [ServiceInfo] = []
            var taps: [TapInfo] = []
            var loadError: Error?
            do {
                switch target {
                case .installed: pkgs = try HomebrewService.installedPackages()
                case .available: available = try HomebrewService.availablePackages()
                case .services:  svcs = try HomebrewService.services()
                case .taps:      taps = try HomebrewService.taps()
                }
            } catch {
                loadError = error
            }
            DispatchQueue.main.async {
                guard let self, self.category == target, self.loadGeneration == generation else { return }
                self.loadingView.stop()
                if let loadError {
                    self.showLoadError(loadError, target: target) { [weak self] in
                        self?.load(target, force: true)
                    }
                    return
                }
                switch target {
                case .installed: self.packages = pkgs
                case .available: self.availablePackages = available
                case .services:  self.services = svcs
                case .taps:      self.taps = taps
                }
                self.loaded.insert(target)
                self.updateToolbarVisibility()
                if target == .available, !self.filterText.isEmpty { self.searchChanged() }
                else { self.applyFilter() }
            }
        }
    }

    private func showLoadError(_ error: Error, target: HomebrewCategory,
                               retry: @escaping () -> Void) {
        emptyState.isHidden = false
        emptyState.configure(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load \(target.title.lowercased())",
            message: error.localizedDescription,
            actionTitle: "Retry",
            action: retry
        )
    }

    private func showNotInstalled() {
        searchGeneration += 1
        loadGeneration += 1
        loadingView.stop()
        packages = []; availablePackages = []; services = []; taps = []
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
        searchGeneration += 1
        let generation = searchGeneration
        guard category != .available || loaded.contains(.available) else { return }
        if category == .available { loadingView.stop() }
        guard category == .available, !filterText.isEmpty else {
            availableSearch = [:]
            applyFilter()
            return
        }

        let query = filterText
        loadingView.startIndeterminate("Searching…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewService.searchWithDescriptions(query) }
            DispatchQueue.main.async {
                guard let self, self.category == .available,
                      self.searchGeneration == generation, self.filterText == query else { return }
                self.loadingView.stop()
                switch result {
                case .success(let matches):
                    self.availableSearch = matches
                    self.applyFilter()
                case .failure(let error):
                    self.showLoadError(error, target: .available) { [weak self] in
                        self?.searchChanged()
                    }
                }
            }
        }
    }

    private func applyFilter() {
        let query = filterText
        switch category {
        case .installed:
            rows = buildPackageRows(query: query)
        case .available:
            let refs = query.isEmpty ? availablePackages : Array(availableSearch.keys)
            rows = buildReferenceRows(refs, descriptions: availableSearch)
        case .services:
            rows = services
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .map(Row.service)
        case .taps:
            rows = taps
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .map(Row.tap)
        }
        tableView.deselectAll(nil)
        onSelect?(nil)
        updateEmptyState()
        tableView.reloadData()
    }

    /// Filter by kind + dependency, then group Casks first, Formulae second.
    private func buildPackageRows(query: String) -> [Row] {
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
        if updatesOnly { pkgs = pkgs.filter(\.isOutdated) }
        if !query.isEmpty {
            pkgs = pkgs.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.token.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query)
            }
        }
        pkgs.sort { packageOrder($0.displayName, $1.displayName) }
        let casks = pkgs.filter(\.isCask)
        let formulae = pkgs.filter { !$0.isCask }
        let showHeaders = (kindFilter == .all)

        var rows: [Row] = []
        if !casks.isEmpty {
            if showHeaders { rows.append(.header("Casks  \(casks.count)")) }
            rows += casks.map(Row.package)
        }
        if !formulae.isEmpty {
            if showHeaders { rows.append(.header("Formulae  \(formulae.count)")) }
            rows += formulae.map(Row.package)
        }
        return rows
    }

    private func buildReferenceRows(_ source: [HomebrewPackageRef],
                                    descriptions: [HomebrewPackageRef: String]) -> [Row] {
        var refs = source.filter { ref in
            switch kindFilter {
            case .all: return true
            case .formulae: return !ref.isCask
            case .casks: return ref.isCask
            }
        }
        refs.sort { packageOrder($0.token, $1.token) }
        let casks = refs.filter(\.isCask)
        let formulae = refs.filter { !$0.isCask }
        let showHeaders = kindFilter == .all
        var result: [Row] = []
        if !casks.isEmpty {
            if showHeaders { result.append(.header("Casks  \(casks.count)")) }
            result += casks.map { .reference($0, description: descriptions[$0] ?? "") }
        }
        if !formulae.isEmpty {
            if showHeaders { result.append(.header("Formulae  \(formulae.count)")) }
            result += formulae.map { .reference($0, description: descriptions[$0] ?? "") }
        }
        return result
    }

    private func packageOrder(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func updateEmptyState() {
        guard HomebrewEnvironment.isInstalled else { return }
        let count = rowCount
        let sourceEmpty: Bool
        switch category {
        case .installed: sourceEmpty = packages.isEmpty
        case .available: sourceEmpty = availablePackages.isEmpty && filterText.isEmpty
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
        case .available: return "Homebrew returned no available formulae or casks."
        case .services:  return "No Homebrew services are configured."
        case .taps:      return "No third-party taps are added."
        }
    }

    // MARK: - Actions

    @objc private func refreshTapped() { load(category, force: true) }
    @objc private func addTapped() { addTap() }
    @objc private func maintenanceTapped() { onMaintenanceRequested?(maintenanceButton) }

    private func addTap() {
        let field = NSTextField(string: "")
        field.placeholderString = "owner/repository"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "Add Homebrew tap"
        alert.informativeText = "Enter a GitHub tap as owner/repository."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add Tap")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = HomebrewActions.validTapName(field.stringValue) else {
            showAlert(title: "Invalid tap", message: "Use owner/repository with letters, numbers, dots, underscores, or hyphens.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = HomebrewActions.runQuiet(HomebrewActions.tapArgs(name))
            DispatchQueue.main.async {
                guard let self else { return }
                if output.ok { self.rescan() }
                else { self.showAlert(title: "Couldn't add tap", message: output.stderr.isEmpty ? output.stdout : output.stderr) }
            }
        }
    }

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
        if category == .installed {
            menu.addItem(.separator())
            add("Include dependencies", includeDependencies, #selector(toggleDependencies))
            add("Updates only", updatesOnly, #selector(toggleUpdatesOnly))
        }
        menu.addItem(.separator())
        add("Name A–Z", sortAscending, #selector(sortAscendingTapped))
        add("Name Z–A", !sortAscending, #selector(sortDescendingTapped))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.height + 4), in: filterButton)
    }

    @objc private func filterAll()      { kindFilter = .all; applyFilter() }
    @objc private func filterFormulae() { kindFilter = .formulae; applyFilter() }
    @objc private func filterCasks()    { kindFilter = .casks; applyFilter() }
    @objc private func toggleDependencies() { includeDependencies.toggle(); applyFilter() }
    @objc private func toggleUpdatesOnly() { updatesOnly.toggle(); applyFilter() }
    @objc private func sortAscendingTapped() { sortAscending = true; applyFilter() }
    @objc private func sortDescendingTapped() { sortAscending = false; applyFilter() }

    // MARK: - Table

    private var rowCount: Int { rows.count }

    private func isHeader(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return true }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let title) = rows[row] {
            let cell = tableView.makeView(withIdentifier: HomebrewHeaderCell.identifier, owner: self) as? HomebrewHeaderCell ?? HomebrewHeaderCell()
            cell.configure(title)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: HomebrewRowCell.identifier, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        switch rows[row] {
        case .header:
            break
        case .package(let package):
            cell.configure(model(for: package))
        case .reference(let ref, let description):
            cell.configure(model(for: ref, description: description))
        case .service(let service):
            cell.configure(model(for: service))
        case .tap(let tap):
            cell.configure(model(for: tap))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeader(row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isHeader(row) ? Metrics.headerRowHeight : Metrics.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeader(row) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rowCount else { onSelect?(nil); return }
        switch rows[row] {
        case .header: onSelect?(nil)
        case .package(let package): onSelect?(.package(package))
        case .reference(let ref, _): onSelect?(.packageReference(ref))
        case .service(let service): onSelect?(.service(service))
        case .tap(let tap): onSelect?(.tap(tap))
        }
    }

    // MARK: - Row models (TapHouse-style tile + pills + version)

    private func model(for package: HomebrewPackage) -> HomebrewRowModel {
        let leading: HomebrewRowModel.Leading
        var pills: [PillSpec] = []
        if package.isCask {
            if let app = package.actualAppURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                leading = .appIcon(NSWorkspace.shared.icon(forFile: app.path))
            } else {
                leading = .glyph(symbol: "macwindow")
            }
            // The source domain used to ride here as a pill, but it duplicated the
            // description, outranked the package name for width, and gave the list a
            // web-dashboard look. It lives in the detail pane's Information grid.
        } else {
            leading = .glyph(symbol: "terminal")
            // Only what changes a decision: "dep" means nothing asked for this
            // directly. A "brew" tag on every row of the Homebrew page said nothing.
            if !package.installedOnRequest { pills.append(PillSpec(text: "dep", color: nil)) }
        }
        if package.isPinned { pills.append(PillSpec(text: "Pinned", color: nil, symbol: "pin.fill")) }
        return HomebrewRowModel(
            leading: leading, title: package.displayName, pills: pills,
            subtitle: package.description, version: package.installedVersion,
            updateAvailable: package.isOutdated)
    }

    private func model(for ref: HomebrewPackageRef, description: String) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: ref.isCask ? "macwindow" : "terminal"),
            title: ref.token,
            pills: [PillSpec(text: ref.isCask ? "Cask" : "Formula", color: nil)],
            subtitle: description
        )
    }

    private func model(for service: ServiceInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "gearshape.2"),
            title: service.name,
            // Symbol + colour, never colour alone: a filled play/stop glyph reads
            // the state in grayscale and under Increased Contrast too.
            pills: service.isRunning
                ? [PillSpec(text: "Running", color: .systemGreen, symbol: "play.fill")]
                : [PillSpec(text: "Stopped", color: nil, symbol: "stop.fill")],
            subtitle: service.user.map { "User: \($0)" } ?? "")
    }

    private func model(for tap: TapInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "arrow.triangle.branch"),
            title: tap.name,
            pills: (tap.official ?? false)
                ? [PillSpec(text: "Official", color: .systemBlue, symbol: "checkmark.seal.fill")]
                : [],
            subtitle: "\(tap.packageCount) package\(tap.packageCount == 1 ? "" : "s")")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
