import AppKit

/// Master list of installed package receipts with a search box. Selecting a row
/// drives the detail pane; refresh re-reads `pkgutil`.
@MainActor
final class PackageListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((PackageReceipt?) -> Void)?

    private var all: [PackageReceipt] = []
    private var filtered: [PackageReceipt] = []
    private var hasScanned = false
    private var filterText = ""

    private let searchField = NSSearchField()
    private let refreshButton = NSButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "shippingbox")
    private static let cellID = NSUserInterfaceItemIdentifier("PackageRow")
    /// Reused per-row instead of allocating a DateFormatter in `viewFor`.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()

    override func loadView() {
        // Sidebar material full-height, continuous under the unified toolbar —
        // same treatment as the app list.
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        searchField.placeholderString = "Search packages"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .rounded
        refreshButton.imagePosition = .imageOnly
        refreshButton.setButtonType(.momentaryPushIn)
        refreshButton.toolTip = "Re-read package receipts"
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        // Inline search + refresh bar at the very top of the list column, mirroring
        // the app-list sidebar.
        let topBar = NSStackView(views: [searchField, refreshButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = Spacing.sm
        topBar.edgeInsets = NSEdgeInsets(top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)

        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        // Transparent so the sidebar's `.sidebar` material shows through the list.
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
            topBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
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

            loadingView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func startIfNeeded() {
        guard !hasScanned else { return }
        hasScanned = true
        rescan()
    }

    @objc private func refresh() { rescan() }

    func rescan() {
        guard PackageScanner.isAvailable() else {
            all = []; applyFilter()
            return
        }
        loadingView.startIndeterminate("Reading package receipts…")
        emptyState.isHidden = true
        onSelect?(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let receipts = PackageScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.all = receipts
                self.applyFilter()
            }
        }
    }

    @objc private func searchChanged() {
        filterText = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    private func applyFilter() {
        if filterText.isEmpty {
            filtered = all
        } else {
            filtered = all.filter {
                $0.id.localizedCaseInsensitiveContains(filterText)
                    || $0.version.localizedCaseInsensitiveContains(filterText)
                    || $0.installLocation.localizedCaseInsensitiveContains(filterText)
            }
        }
        emptyState.isHidden = !filtered.isEmpty
        if filtered.isEmpty {
            emptyState.configure(symbol: all.isEmpty ? "lock.shield" : "magnifyingglass",
                                 title: all.isEmpty ? "No package receipts found" : "No matches",
                                 message: all.isEmpty ? "BetterCleaner needs Full Disk Access to read package receipts." : "")
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? PackageRowCell ?? PackageRowCell()
        let receipt = filtered[row]
        var detail: [String] = []
        if !receipt.version.isEmpty { detail.append("v\(receipt.version)") }
        if let date = receipt.installDate {
            detail.append(Self.dateFormatter.string(from: date))
        }
        cell.configure(title: receipt.id, subtitle: detail.joined(separator: " · "))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onSelect?(row >= 0 && row < filtered.count ? filtered[row] : nil)
    }
}

private final class PackageRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("PackageRow")
        for v in [icon, title, subtitle] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        icon.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = Typography.subheadline
        subtitle.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.badgeSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Spacing.sm),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs + 1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.sm),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.sm),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title: String, subtitle: String) {
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.subtitle.isHidden = subtitle.isEmpty
    }
}
