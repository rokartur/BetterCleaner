import AppKit

/// The app's primary navigation: a native source-list sidebar that lists every
/// page grouped into Cleanup / Tools / System, laid out 1:1 with the BetterSettings
/// tab list (9pt selection capsule, 32pt rows, accent-tinted SF Symbols, no
/// gradient tiles) — with an optional trailing reclaimable size on the scannable
/// pages.
///
/// Selecting a row reports its id via `onSelect`. `selectRow(_:)` mirrors a
/// programmatic page change (launch / drop / deep link) onto the list without
/// re-firing `onSelect`, so there is no selection feedback loop.
@MainActor
final class NavSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Fired when the user picks a page row. Not fired by `selectRow(_:)`.
    var onSelect: ((String) -> Void)?

    private enum Row {
        case header(String)
        case section(NavSection)
    }

    private static let headerCellID = NSUserInterfaceItemIdentifier("NavHeaderCell")

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    /// Top inset of the list, kept in sync with the traffic-light position so the
    /// first row clears the close button by the BetterSettings offset.
    private var scrollTopConstraint: NSLayoutConstraint?
    private var rows: [Row] = []
    /// Reclaimable bytes per page id (Junk / Orphaned / Development), shown trailing.
    private var sizes: [String: Int64] = [:]
    /// The page id the sidebar should show selected; applied once the view loads.
    private var selectedID: String?
    /// Suppresses `onSelect` while we mirror a programmatic selection.
    private var isProgrammaticSelection = false

    override func loadView() {
        // Drive the sidebar material full-height so it's continuous under the
        // unified toolbar (the split is nested in RootViewController, so the
        // automatic sidebar vibrancy doesn't reach the titlebar band on its own).
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Full-width cells + a custom row view (NavRowView) draw the rounded
        // selection capsule ourselves, so the pill sits exactly 9pt from the edges
        // and content padding is precise — instead of the wide default source-list
        // inset. (BetterSettings does the same.)
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.floatsGroupRows = false
        // Zero intercell spacing → tight rows like the BetterSettings tab list.
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        // Allow empty selection so `reloadData()` in `buildRows()` doesn't force an
        // auto-selection (which would fire `onSelect` re-entrantly during the split's
        // setup, before the other columns exist). Selection is driven explicitly via
        // `selectRow(_:)`, so there's always a row selected once the page is set.
        tableView.allowsEmptySelection = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Offset the first row below the traffic lights by the BetterSettings
        // amount; refined in `viewDidLayout` from the real close-button position.
        let scrollTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 46)
        scrollTopConstraint = scrollTop
        NSLayoutConstraint.activate([
            scrollTop,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        buildRows()
        applySelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTopInsetForTrafficLights()
    }

    /// Keep the list's top inset a fixed gap below the traffic lights, exactly like
    /// BetterSettings positions its search field (so the top of the sidebar reads
    /// identically regardless of titlebar height).
    private func updateTopInsetForTrafficLights() {
        guard let scrollTopConstraint else { return }
        var topInset: CGFloat = 46
        if let window = view.window, let closeButton = window.standardWindowButton(.closeButton) {
            let frameInView = view.convert(closeButton.bounds, from: closeButton)
            let topToButtonBottom = max(0, view.bounds.maxY - frameInView.minY)
            topInset = min(max(topToButtonBottom + Metrics.sidebarTrafficLightOffset, 10), 140)
        }
        if abs(scrollTopConstraint.constant - topInset) > 0.5 {
            scrollTopConstraint.constant = topInset
        }
    }

    private func buildRows() {
        var rows: [Row] = []
        for group in NavCatalog.groups {
            let items = group.items.filter { $0.enabled }
            guard !items.isEmpty else { continue }
            rows.append(.header(group.title))
            rows += items.map { .section($0) }
        }
        self.rows = rows
        tableView.reloadData()
    }

    // MARK: - Public API

    /// Mirror a programmatic page change onto the sidebar without re-firing
    /// `onSelect`. Stored and re-applied if the view isn't loaded yet.
    func selectRow(_ id: String) {
        selectedID = id
        applySelection()
    }

    /// Show a reclaimable size trailing the page row (Junk / Orphaned / Development).
    func setSize(_ id: String, _ bytes: Int64) {
        sizes[id] = bytes
        guard isViewLoaded, let idx = rowIndex(of: id) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integer: 0))
    }

    private func rowIndex(of id: String) -> Int? {
        rows.firstIndex { if case .section(let s) = $0 { return s.id == id }; return false }
    }

    private func applySelection() {
        guard isViewLoaded, let id = selectedID, let idx = rowIndex(of: id) else { return }
        guard tableView.selectedRow != idx else { return }
        isProgrammaticSelection = true
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        isProgrammaticSelection = false
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
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("NavRow")
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NavRowView { return reused }
        let rv = NavRowView()
        rv.identifier = id
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: Self.headerCellID, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = Self.headerCellID
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                // Finder sidebar group-header style: title-case, semibold, gray.
                tf.font = Typography.semibold(.subheadline)
                tf.textColor = .secondaryLabelColor
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Metrics.sidebarHeaderInset),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = title
            return cell

        case .section(let s):
            let cell = tableView.makeView(withIdentifier: NavCell.identifier, owner: self) as? NavCell ?? {
                let c = NavCell(frame: .zero)
                c.identifier = NavCell.identifier
                return c
            }()
            cell.configure(symbol: s.icon, title: s.title, size: sizes[s.id], color: s.color)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .section(let s) = rows[row] else { return }
        selectedID = s.id
        onSelect?(s.id)
    }
}

/// Draws the rounded selection capsule itself (like BetterSettings' SidebarRowView)
/// so the pill sits a precise 9pt from the sidebar edges instead of the wider
/// default source-list inset. Accent fill on the key window, gray otherwise.
final class NavRowView: NSTableRowView {
    private let inset = Metrics.sidebarRowPadding
    private let cornerRadius = Metrics.sidebarSelectionRadius

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let width = max(0, bounds.width - inset * 2)
        guard width > 0, bounds.height > 0 else { return }
        let rect = NSRect(x: inset, y: 0, width: width, height: bounds.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        (isEmphasized ? NSColor.controlAccentColor : .unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
    }

    /// Force the cell's `backgroundStyle` to `.emphasized` only on the accent
    /// (key-window) capsule, so the glyph + text invert to white there and stay
    /// accent/label on the muted unemphasized capsule.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        (isSelected && isEmphasized) ? .emphasized : .normal
    }
}
