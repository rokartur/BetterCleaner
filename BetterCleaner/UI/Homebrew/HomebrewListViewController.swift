import AppKit

/// Master column for the Homebrew pages. Shows one category at a time — chosen by the
/// Homebrew sidebar rows (Installed / Services / Taps) via `setCategory(_:)` — with a
/// search box, an "install new" (+) button (Installed only), a maintenance (…) menu,
/// and a refresh button. Selecting a row drives the detail pane via `onSelect`.
///
/// Mirrors `PackageListViewController`. Categories are cached + lazily loaded so
/// revisiting a tab is instant.
@MainActor
final class HomebrewListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((HomebrewSelection?) -> Void)?
    /// Tapped "+" — the host should present the search & install sheet.
    var onAddRequested: (() -> Void)?
    /// Tapped "…" — the host presents the maintenance menu, anchored to the button.
    var onMaintenanceRequested: ((NSButton) -> Void)?

    private var category: HomebrewCategory = .installed
    private var loaded: Set<HomebrewCategory> = []

    private var packages: [HomebrewPackage] = []
    private var services: [ServiceInfo] = []
    private var taps: [TapInfo] = []

    private var filteredPackages: [HomebrewPackage] = []
    private var filteredServices: [ServiceInfo] = []
    private var filteredTaps: [TapInfo] = []

    private var filterText = ""

    private let searchField = NSSearchField()
    private let addButton = NSButton()
    private let maintenanceButton = NSButton()
    private let refreshButton = NSButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "cup.and.saucer")
    private static let cellID = HomebrewRowCell.identifier

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

        configureToolButton(addButton, symbol: "plus", tip: "Search & install a package", action: #selector(addTapped))
        configureToolButton(maintenanceButton, symbol: "ellipsis.circle", tip: "Maintenance (update, cleanup, Brewfile…)", action: #selector(maintenanceTapped))
        configureToolButton(refreshButton, symbol: "arrow.clockwise", tip: "Refresh", action: #selector(refreshTapped))

        let actionsRow = NSStackView(views: [searchField, addButton, maintenanceButton, refreshButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = Spacing.sm
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(actionsRow)

        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.rowHeight = 52
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

    /// Switch to a category (driven by the Homebrew sidebar rows) and load it.
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
        // "Install new" only makes sense on the Installed list.
        addButton.isHidden = category != .installed
    }

    /// Public re-scan used after a mutation: invalidate every cache and reload the
    /// visible category (the action may have changed packages, services, or taps).
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
        // Clear the table immediately so the previous tab's rows don't show behind
        // the spinner while the new category loads.
        filteredPackages = []; filteredServices = []; filteredTaps = []
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
        filteredPackages = q.isEmpty ? packages : packages.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.token.localizedCaseInsensitiveContains(q)
                || $0.description.localizedCaseInsensitiveContains(q)
        }
        filteredServices = q.isEmpty ? services : services.filter { $0.name.localizedCaseInsensitiveContains(q) }
        filteredTaps = q.isEmpty ? taps : taps.filter { $0.name.localizedCaseInsensitiveContains(q) }

        let count = rowCount
        let sourceEmpty: Bool
        switch category {
        case .installed: sourceEmpty = packages.isEmpty
        case .services:  sourceEmpty = services.isEmpty
        case .taps:      sourceEmpty = taps.isEmpty
        }

        if HomebrewEnvironment.isInstalled {
            emptyState.isHidden = count != 0
            if count == 0 {
                emptyState.configure(
                    symbol: sourceEmpty ? "cup.and.saucer" : "magnifyingglass",
                    title: sourceEmpty ? "No \(category.title.lowercased())" : "No matches",
                    message: sourceEmpty ? emptyMessage(for: category) : ""
                )
            }
        }
        tableView.reloadData()
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

    // MARK: - Table

    private var rowCount: Int {
        switch category {
        case .installed: return filteredPackages.count
        case .services:  return filteredServices.count
        case .taps:      return filteredTaps.count
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        switch category {
        case .installed: cell.configure(model(for: filteredPackages[row]))
        case .services:  cell.configure(model(for: filteredServices[row]))
        case .taps:      cell.configure(model(for: filteredTaps[row]))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rowCount else { onSelect?(nil); return }
        switch category {
        case .installed: onSelect?(.package(filteredPackages[row]))
        case .services:  onSelect?(.service(filteredServices[row]))
        case .taps:      onSelect?(.tap(filteredTaps[row]))
        }
    }

    // MARK: - Row models (TapHouse-style tile + tags + version)

    private func model(for p: HomebrewPackage) -> HomebrewRowModel {
        let leading: HomebrewRowModel.Leading
        if p.isCask {
            let appPath = "/Applications/\(p.displayName).app"
            if FileManager.default.fileExists(atPath: appPath) {
                leading = .appIcon(NSWorkspace.shared.icon(forFile: appPath))
            } else {
                leading = .glyph(symbol: "macwindow", color: .systemGray)
            }
        } else {
            leading = .glyph(symbol: "shippingbox", color: .systemGreen)
        }
        var tags = [p.isCask ? "Cask" : "Formula"]
        if !p.isCask, !p.installedOnRequest { tags.append("dep") }
        var status: (String, NSColor)?
        if p.isOutdated { status = ("Update", .systemOrange) }
        else if p.isPinned { status = ("Pinned", .systemGray) }
        return HomebrewRowModel(
            leading: leading, title: p.displayName, tags: tags, status: status,
            subtitle: p.description, version: p.installedVersion,
            newVersion: p.isOutdated ? p.latestVersion : nil)
    }

    private func model(for s: ServiceInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "gearshape.2", color: s.isRunning ? .systemGreen : .systemGray),
            title: s.name,
            status: s.isRunning ? ("Running", .systemGreen) : ("Stopped", .systemGray),
            subtitle: s.user.map { "User: \($0)" } ?? "")
    }

    private func model(for t: TapInfo) -> HomebrewRowModel {
        HomebrewRowModel(
            leading: .glyph(symbol: "arrow.triangle.branch", color: .systemBlue),
            title: t.name,
            tags: (t.official ?? false) ? ["Official"] : [],
            subtitle: "\(t.packageCount) package\(t.packageCount == 1 ? "" : "s")")
    }
}
