import AppKit

/// Sheet to search Homebrew and install a new formula or cask. Results come from
/// `brew search`; the selected result's description loads lazily via `brew info`.
/// Installing runs in the streaming progress sheet; `onChanged` refreshes the list.
@MainActor
final class HomebrewSearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let onChanged: () -> Void
    private var results: [HomebrewService.SearchHit] = []
    private var descriptions: [String: String] = [:]

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "magnifyingglass")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var installButton = Buttons.primary("Install", target: self, action: #selector(install))
    private lazy var closeButton = Buttons.secondary("Close", target: self, action: #selector(closeSheet))
    private static let cellID = HomebrewRowCell.identifier

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        searchField.placeholderString = "Search formulae & casks"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.sendsSearchStringImmediately = false

        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(install)
        tableView.target = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        detailLabel.font = Typography.footnote
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.isEnabled = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [detailLabel, closeButton, installButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSView()
        for v in [searchField, scrollView, footer, emptyState, loadingView] { root.addSubview(v) }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.configure(symbol: "magnifyingglass", title: "Search Homebrew",
                             message: "Type a name to find formulae and casks to install.")

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),
            root.heightAnchor.constraint(equalToConstant: 440),

            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.md),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.lg),

            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        view = root
    }

    @objc private func runSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        results = []
        descriptions = [:]
        installButton.isEnabled = false
        detailLabel.stringValue = ""
        tableView.reloadData()
        guard !query.isEmpty else { emptyState.isHidden = false; return }

        emptyState.isHidden = true
        loadingView.startIndeterminate("Searching…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = HomebrewService.search(query)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.results = hits
                self.emptyState.isHidden = !hits.isEmpty
                if hits.isEmpty {
                    self.emptyState.configure(symbol: "magnifyingglass", title: "No matches",
                                              message: "No formulae or casks match “\(query)”.")
                }
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        let hit = results[row]
        let symbol = hit.isCask ? "macwindow" : "shippingbox"
        cell.configure(icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                       title: hit.token, subtitle: descriptions[hit.token] ?? "",
                       badgeText: hit.isCask ? "Cask" : "Formula",
                       badgeColor: hit.isCask ? .systemBlue : .systemIndigo)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { installButton.isEnabled = false; detailLabel.stringValue = ""; return }
        installButton.isEnabled = true
        let hit = results[row]
        if let cached = descriptions[hit.token] {
            detailLabel.stringValue = cached
            return
        }
        detailLabel.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = HomebrewService.info(token: hit.token, isCask: hit.isCask)
            let desc = info?.description ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.descriptions[hit.token] = desc
                if self.tableView.selectedRow == row { self.detailLabel.stringValue = desc }
                self.tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    // MARK: - Actions

    @objc private func install() {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        let hit = results[row]
        let sheet = HomebrewProgressViewController(
            title: "Installing \(hit.token)…",
            arguments: HomebrewActions.installArgs(token: hit.token, isCask: hit.isCask)
        ) { [onChanged] success in
            if success { onChanged() }
        }
        presentAsSheet(sheet)
    }

    @objc private func closeSheet() { dismiss(self) }
}
