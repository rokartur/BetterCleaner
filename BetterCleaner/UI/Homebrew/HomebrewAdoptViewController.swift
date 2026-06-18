import AppKit

/// Sheet that lists `/Applications` apps which match a known Homebrew cask but were
/// installed by hand, and lets the user "adopt" the selected ones so Homebrew manages
/// their updates (`brew install --cask --adopt …`). Multi-select the rows to adopt.
@MainActor
final class HomebrewAdoptViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let onChanged: () -> Void
    private var candidates: [HomebrewAdopter.Candidate] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "wand.and.stars")
    private lazy var selectAllButton = Buttons.secondary("Select All", target: self, action: #selector(selectAllRows))
    private lazy var adoptButton = Buttons.primary("Adopt Selected", target: self, action: #selector(adopt))
    private lazy var closeButton = Buttons.secondary("Close", target: self, action: #selector(closeSheet))
    private static let cellID = HomebrewRowCell.identifier

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Adopt Installed Apps")
        title.font = Typography.semibold(.headline)
        let subtitle = NSTextField(wrappingLabelWithString: "Apps you installed by hand that match a Homebrew cask. Select the ones you want Homebrew to manage from now on.")
        subtitle.font = Typography.footnote
        subtitle.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.rowHeight
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        adoptButton.isEnabled = false
        let footer = NSStackView(views: [selectAllButton, NSView(), closeButton, adoptButton])
        footer.orientation = .horizontal
        footer.spacing = Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false
        (footer.arrangedSubviews[1]).setContentHuggingPriority(.defaultLow, for: .horizontal)

        let head = NSStackView(views: [title, subtitle])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = Spacing.xs
        head.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [head, scrollView, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),
            root.heightAnchor.constraint(equalToConstant: 440),

            head.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: head.bottomAnchor, constant: Spacing.md),
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

    override func viewDidAppear() {
        super.viewDidAppear()
        guard candidates.isEmpty else { return }
        scan()
    }

    private func scan() {
        emptyState.isHidden = true
        loadingView.startIndeterminate("Scanning /Applications…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = HomebrewAdopter.candidates()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.candidates = found
                self.emptyState.isHidden = !found.isEmpty
                if found.isEmpty {
                    self.emptyState.configure(symbol: "checkmark.seal",
                                              title: "Nothing to adopt",
                                              message: "Every matching app is already managed by Homebrew.")
                }
                self.selectAllButton.isEnabled = !found.isEmpty
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        let c = candidates[row]
        let icon = FileManager.default.fileExists(atPath: c.appPath)
            ? NSWorkspace.shared.icon(forFile: c.appPath)
            : NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        cell.configure(icon: icon, title: c.appName, subtitle: "Cask: \(c.caskToken)", badgeText: nil, badgeColor: .clear)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        adoptButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Actions

    @objc private func selectAllRows() {
        tableView.selectRowIndexes(IndexSet(0..<candidates.count), byExtendingSelection: false)
        adoptButton.isEnabled = !candidates.isEmpty
    }

    @objc private func adopt() {
        let tokens = tableView.selectedRowIndexes.map { candidates[$0].caskToken }
        guard !tokens.isEmpty else { return }
        let sheet = HomebrewProgressViewController(
            title: "Adopting \(tokens.count) app\(tokens.count == 1 ? "" : "s")…",
            arguments: HomebrewActions.adoptArgs(tokens: tokens)
        ) { [onChanged] success in
            if success { onChanged() }
        }
        presentAsSheet(sheet)
    }

    @objc private func closeSheet() { dismiss(self) }
}
