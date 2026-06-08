import AppKit

/// Detail pane for one installed package: its metadata, the files it installed
/// (its Bill of Materials, pre-selected), and actions to Forget the receipt or
/// Uninstall (trash files + forget). Files go to the Trash (recoverable).
@MainActor
final class PackageDetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called after a forget/uninstall so the master list can refresh.
    var onChanged: (() -> Void)?

    private var receipt: PackageReceipt?
    private var items: [FileItem] = []

    private let header = PageHeaderView(titleTruncation: .byTruncatingMiddle)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "shippingbox")
    private lazy var selectAllButton = Buttons.secondary("Select All", target: self, action: #selector(toggleSelectAll))
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var forgetButton = Buttons.secondary("Forget Receipt", target: self, action: #selector(forget))
    private lazy var uninstallButton = Buttons.destructive("Uninstall", target: self, action: #selector(uninstall))

    override func loadView() {
        if let s = NavCatalog.section(id: "pkg") { header.setBadge(symbol: s.icon, tint: s.tint) }
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(revealClickedRow)
        let menu = NSMenu()
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealClickedRow), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
        tableView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        tableView.style = .inset

        // Flat list on the window surface — no card. The scroll view draws no
        // background so the table reads on the content background.

        // Empty state self-styles.

        // Glass action bar. Uninstall is destructive (red, Return); Forget only
        // removes the install record, so it stays a neutral secondary.
        statusLabel.font = Typography.subheadline
        statusLabel.textColor = .secondaryLabelColor
        forgetButton.toolTip = "Remove the install record only — files stay on disk."
        uninstallButton.toolTip = "Move the selected installed files to the Trash, then forget the receipt."
        let footer = ActionBarView(leading: [selectAllButton, statusLabel], trailing: [forgetButton, uninstallButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [header, scrollView, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.sm),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.md),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        view = root
        showPlaceholder()
    }

    // MARK: - Loading

    func show(_ receipt: PackageReceipt?) {
        self.receipt = receipt
        guard let receipt else { showPlaceholder(); return }

        items = []
        tableView.reloadData()
        header.title = receipt.id
        header.summary = metadataLine(receipt)
        header.detail = "Receipt: /var/db/receipts/\(receipt.id).plist"
        emptyState.isHidden = true
        loadingView.startIndeterminate("Reading installed files…")
        updateFooter()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = PackageScanner.fileItems(id: receipt.id)
            DispatchQueue.main.async {
                guard let self, self.receipt?.id == receipt.id else { return }
                self.loadingView.stop()
                self.items = files
                let bytes = files.reduce(Int64(0)) { $0 + $1.size }
                self.header.summary = self.metadataLine(receipt) + " · \(files.count) file\(files.count == 1 ? "" : "s") · \(FileSize.string(bytes))"
                self.emptyState.isHidden = !files.isEmpty
                if files.isEmpty {
                    self.emptyState.configure(symbol: "doc.questionmark",
                                              title: "No files recorded",
                                              message: "This package's receipt lists no removable files.")
                }
                self.tableView.reloadData()
                self.updateFooter()
            }
        }
    }

    private func showPlaceholder() {
        receipt = nil
        items = []
        loadingView.stop()
        tableView.reloadData()
        header.title = ""
        header.summary = ""
        header.detail = ""
        emptyState.configure(symbol: "shippingbox",
                             title: "Select a package",
                             message: "Choose a package to see the files it installed.")
        emptyState.isHidden = false
        updateFooter()
    }

    private func metadataLine(_ receipt: PackageReceipt) -> String {
        var parts: [String] = []
        if !receipt.version.isEmpty { parts.append("v\(receipt.version)") }
        if let date = receipt.installDate {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            parts.append("installed \(f.string(from: date))")
        }
        if !receipt.installLocation.isEmpty, receipt.installLocation != "/" { parts.append(receipt.installLocation) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var selectedItems: [FileItem] { items.filter { $0.isSelected } }

    private func updateFooter() {
        let selected = selectedItems
        let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
        statusLabel.stringValue = items.isEmpty ? "" : (selected.isEmpty ? "No files selected" : "\(selected.count) of \(items.count) · \(FileSize.string(bytes))")
        selectAllButton.isEnabled = !items.isEmpty
        selectAllButton.title = (!items.isEmpty && items.allSatisfy { $0.isSelected }) ? "Deselect All" : "Select All"
        forgetButton.isEnabled = receipt != nil
        uninstallButton.isEnabled = receipt != nil
    }

    @objc private func toggleSelectAll() {
        guard !items.isEmpty else { return }
        let selectAll = !items.allSatisfy { $0.isSelected }
        for item in items { item.isSelected = selectAll }
        tableView.reloadData()
        updateFooter()
    }

    @objc private func revealClickedRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let url = items[row].url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Actions

    /// A still-installed `.app` from this package's files, if any (used to block a
    /// receipt-only forget that would orphan a live app).
    private func existingAppBundle() -> URL? {
        items.first { $0.url.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.url.path) }?.url
    }

    @objc private func forget() {
        guard let receipt else { return }
        if let app = existingAppBundle() {
            let alert = NSAlert()
            alert.messageText = "App Bundle Still Exists"
            alert.informativeText = "\(app.lastPathComponent) is still installed. Remove the app first (Applications tab), or use Uninstall to remove its files and the receipt together."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Forget “\(receipt.id)”?"
        alert.informativeText = "Removes the install record only — files already on disk stay."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let id = receipt.id
        loadingView.startIndeterminate("Forgetting receipt…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = PackageScanner.forget(ids: [id])
            if error == nil { TrashHistory.recordRemoval(origin: "Package: \(id)", items: [id], bytes: 0, at: Date()) }
            DispatchQueue.main.async {
                self?.loadingView.stop()
                if let error, error != "cancelled" { self?.alertFailure("Couldn't Forget Receipt", error) }
                self?.onChanged?()
            }
        }
    }

    @objc private func uninstall() {
        guard let receipt else { return }
        let selected = selectedItems
        if Preferences.shared.confirmBeforeDelete {
            let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
            let alert = NSAlert()
            alert.messageText = "Uninstall “\(receipt.id)”?"
            alert.informativeText = selected.isEmpty
                ? "No files selected — this only forgets the install record."
                : "Move \(selected.count) file\(selected.count == 1 ? "" : "s") · \(FileSize.string(bytes)) to the Trash (restorable), then forget the receipt. System files require an admin password."
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let id = receipt.id
        loadingView.startIndeterminate("Uninstalling \(id)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome: Trasher.Outcome?
            if !selected.isEmpty { outcome = Trasher.trash(selected, origin: "Package: \(id)") }

            // Forget the receipt only once no .app of this package remains, so we
            // never orphan a still-installed app.
            let appRemains = PackageScanner.bomFiles(id: id).contains {
                $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.path)
            }
            var forgetError: String?
            if !appRemains { forgetError = PackageScanner.forget(ids: [id]) }

            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                if let outcome, !outcome.failed.isEmpty {
                    self.alertFailure("Some Files Couldn't Be Removed", "\(outcome.trashed.count) moved to Trash, \(outcome.failed.count) failed.")
                } else if appRemains {
                    self.alertFailure("Receipt Kept", "Files were moved to the Trash, but the receipt was kept because the app bundle is still installed. Remove the app to forget the receipt.")
                } else if let forgetError, forgetError != "cancelled" {
                    self.alertFailure("Couldn't Forget Receipt", forgetError)
                }
                self.onChanged?()
            }
        }
    }

    private func alertFailure(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: self) as? FileCell ?? {
            let c = FileCell()
            c.identifier = FileCell.identifier
            return c
        }()
        cell.configure(item: items[row])
        cell.onToggle = { [weak self] in self?.updateFooter() }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
