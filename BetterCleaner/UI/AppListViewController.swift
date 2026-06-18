import AppKit

/// The installed-apps sidebar: a searchable, sortable table split into two
/// grouped sections — **Installed Apps** (user-removable) and **System Apps**
/// (`/System`, read-only). Selecting a row (or dropping a `.app`) reports the
/// app to `onSelect`. App bundle sizes are computed lazily off the main thread.
final class AppListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((InstalledApp) -> Void)?
    /// Fired when the inline refresh button is clicked; the owner re-enumerates
    /// installed apps. Lives here (not the toolbar) so search + refresh stay
    /// scoped to the Applications list column.
    var onRefresh: (() -> Void)?

    private enum Row {
        case header(String)
        case app(InstalledApp)
    }

    private static let headerCellID = NSUserInterfaceItemIdentifier("AppListHeaderCell")

    private let searchField = NSSearchField()
    private let sortButton = NSButton()
    private let refreshButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyState = EmptyStateView(symbol: "square.grid.2x2")

    private var allApps: [InstalledApp] = []
    private var rows: [Row] = []
    private var sizes: [URL: Int64] = [:]
    private var filterText = ""
    private var sortBySize = Preferences.shared.sortBySize
    private var sizeGeneration = 0

    override func loadView() {
        // This is the middle master-list column (between the navigation sidebar and
        // the detail), so it reads as content — a `.contentBackground` material, not
        // the sidebar's vibrancy — and stays continuous under the unified toolbar.
        let container = NSVisualEffectView()
        container.material = .contentBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        // Transparent so the column's content material shows through the list
        // exactly like it does behind the search header — otherwise the table paints
        // an opaque controlBackground and the list reads a different colour.
        tableView.backgroundColor = .clear
        // Match the main navigation sidebar's compact rows.
        tableView.rowHeight = Metrics.compactRowHeight
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true

        // Inline search + refresh bar at the very top of the list column. Only
        // exists here, so it's automatically present only while the Applications
        // section is shown.
        searchField.placeholderString = "Search apps"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
        sortButton.bezelStyle = .rounded
        sortButton.imagePosition = .imageOnly
        sortButton.setButtonType(.momentaryPushIn)
        sortButton.toolTip = "Sort the app list"
        sortButton.target = self
        sortButton.action = #selector(sortClicked)
        sortButton.setContentHuggingPriority(.required, for: .horizontal)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.imagePosition = .imageOnly
        refreshButton.setButtonType(.momentaryPushIn)
        refreshButton.toolTip = "Refresh the app list"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        let topBar = NSStackView(views: [searchField, sortButton, refreshButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = Spacing.sm
        topBar.edgeInsets = NSEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        container.addSubview(scrollView)

        emptyState.isHidden = true
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.xs),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    @objc private func searchChanged() {
        setFilter(searchField.stringValue)
    }

    @objc private func refreshClicked() {
        onRefresh?()
    }

    /// Pop a small menu under the sort button: Name (A→Z) or Size (largest
    /// first), checkmark on the active key. The choice persists in `Preferences`
    /// so it survives relaunch and stays in sync with any other reader.
    @objc private func sortClicked() {
        let menu = NSMenu()
        let byName = NSMenuItem(title: "Name", action: #selector(sortByName), keyEquivalent: "")
        byName.target = self
        byName.state = sortBySize ? .off : .on
        let bySize = NSMenuItem(title: "Size", action: #selector(sortBySizeSelected), keyEquivalent: "")
        bySize.target = self
        bySize.state = sortBySize ? .on : .off
        menu.addItem(byName)
        menu.addItem(bySize)
        let origin = NSPoint(x: 0, y: sortButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: sortButton)
    }

    @objc private func sortByName() { applySort(bySize: false) }
    @objc private func sortBySizeSelected() { applySort(bySize: true) }

    private func applySort(bySize: Bool) {
        Preferences.shared.sortBySize = bySize
        setSortBySize(bySize)
    }

    // MARK: - Public API

    func reload(with apps: [InstalledApp]) {
        allApps = apps
        sizes.removeAll()
        applyFilterAndSort()
        computeSizes()
    }

    func setFilter(_ text: String) {
        filterText = text
        applyFilterAndSort()
    }

    func setSortBySize(_ on: Bool) {
        sortBySize = on
        applyFilterAndSort()
    }

    /// Reset transient view state (used when this controller is reused) so a
    /// prior filter/sort doesn't leak into the next show.
    func reset() {
        filterText = ""
        searchField.stringValue = ""
        sortBySize = Preferences.shared.sortBySize
        applyFilterAndSort()
    }

    // MARK: - Filtering / sorting

    private func applyFilterAndSort() {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? allApps : allApps.filter {
            $0.name.lowercased().contains(needle) || ($0.bundleID?.lowercased().contains(needle) ?? false)
        }

        let sortInSection: ([InstalledApp]) -> [InstalledApp] = { [self] apps in
            if sortBySize {
                return apps.sorted { (sizes[$0.url] ?? 0, $0.name.lowercased()) > (sizes[$1.url] ?? 0, $1.name.lowercased()) }
            }
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let installed = sortInSection(filtered.filter { !$0.isSystem })
        let system = sortInSection(filtered.filter { $0.isSystem })

        var rows: [Row] = []
        if !installed.isEmpty {
            rows.append(.header("Installed Apps (\(installed.count))"))
            rows += installed.map { .app($0) }
        }
        if !system.isEmpty {
            rows.append(.header("System Apps (\(system.count))"))
            rows += system.map { .app($0) }
        }
        self.rows = rows
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasApps = rows.contains { if case .app = $0 { return true }; return false }
        emptyState.isHidden = hasApps
        guard !hasApps else { return }
        let searching = !filterText.trimmingCharacters(in: .whitespaces).isEmpty
        emptyState.configure(
            symbol: searching ? "magnifyingglass" : "square.grid.2x2",
            title: searching ? "No matches" : "No applications found",
            message: searching ? "" : "Drop a .app here, or add scan locations in Settings."
        )
    }

    private func appRowIndex(of app: InstalledApp) -> Int? {
        rows.firstIndex {
            if case .app(let a) = $0 { return a == app }
            return false
        }
    }

    private func computeSizes() {
        sizeGeneration += 1
        let generation = sizeGeneration
        let apps = allApps
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for app in apps {
                let size = FileSize.size(of: app.url)
                DispatchQueue.main.async { [weak self] in
                    // Sizes drive both the visible row size column and the optional
                    // sort-by-size order. Refresh just this app's row as its size
                    // lands (FileSize.size walks the tree, so they arrive spaced
                    // out) — a one-row reload, not a full-table storm.
                    guard let self, generation == self.sizeGeneration else { return }
                    self.sizes[app.url] = size
                    if let idx = self.appRowIndex(of: app) {
                        self.tableView.reloadData(forRowIndexes: IndexSet(integer: idx),
                                                  columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.sizeGeneration, self.sortBySize else { return }
                self.applyFilterAndSort()
            }
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return Metrics.headerRowHeight }
        return Metrics.compactRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .app = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: Self.headerCellID, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = Self.headerCellID
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = Typography.semibold(.caption1)
                tf.textColor = .secondaryLabelColor
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    // Indent to the app-row text edge and center vertically so the
                    // group label lines up with rows like a Finder/Music source list.
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Spacing.sm),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = title.uppercased()
            return cell

        case .app(let app):
            let cell = tableView.makeView(withIdentifier: AppCell.identifier, owner: self) as? AppCell ?? {
                let c = AppCell(frame: .zero)
                c.identifier = AppCell.identifier
                return c
            }()
            cell.configure(app: app, size: sizes[app.url])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .app(let app) = rows[row] else { return }
        onSelect?(app)
    }

}
