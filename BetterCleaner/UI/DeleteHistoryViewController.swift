import AppKit

/// Master-detail view of `TrashHistory`: removal batches on the left, the files
/// of the selected batch on the right (with per-file restore checkboxes and a
/// colour-coded status pill), and a Restore button that moves the checked,
/// recoverable files back to their original locations. Follows the shared content
/// scaffold: page header (+ badge), a search/clear toolbar, flat lists, a glass
/// action bar, and shared empty/loading states.
@MainActor
final class DeleteHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    /// Every recorded batch, newest first.
    private var entries: [TrashHistory.Entry] = []
    /// `entries` after the search filter — the batch list and selection index into
    /// this, not `entries`.
    private var visibleEntries: [TrashHistory.Entry] = []
    private var searchText = ""

    private var selectedFiles: [TrashHistory.FileRecord] = []
    /// True when the selected batch was only *logged* (Homebrew uninstall, package
    /// forget) and carries no per-file restore data — its rows are shown as
    /// "Removed" and can't be restored.
    private var selectedIsLogged = false
    /// Original paths the user has ticked for restore (defaults to every
    /// restorable file in the selected batch). Reset on each batch selection.
    private var checkedPaths: Set<String> = []
    /// Memoised `FileStatus` per record for one reload — a batch reload otherwise
    /// re-stats every file of every batch (restorable-count pills) on the main
    /// thread. Cleared on each `reload()`.
    private var statusCache: [String: FileStatus] = [:]

    private let header = PageHeaderView()
    private let searchField = NSSearchField()
    private let batchTable = NSTableView()
    private let fileTable = NSTableView()
    private let batchScroll = NSScrollView()
    private let fileScroll = NSScrollView()
    private lazy var refreshButton = Buttons.secondary("Refresh", target: self, action: #selector(reloadClicked))
    private lazy var selectAllButton = Buttons.secondary("Select All", target: self, action: #selector(selectAllToggle))
    private lazy var clearButton = Buttons.secondary("Clear History", target: self, action: #selector(clearHistoryClicked))
    private lazy var restoreButton = Buttons.primary("Restore", target: self, action: #selector(restoreSelected))
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = EmptyStateView(symbol: "clock.arrow.circlepath")
    private let loadingView = LoadingStateView()

    private static let batchCellID = NSUserInterfaceItemIdentifier("BatchCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("FileRecordCell")

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "Today 14:32" / "Yesterday 09:10" / "3 Mar 2026 at 14:32".
    private func friendlyDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today \(timeFormatter.string(from: date))" }
        if cal.isDateInYesterday(date) { return "Yesterday \(timeFormatter.string(from: date))" }
        return dateFormatter.string(from: date)
    }

    override func loadView() {
        if let s = NavCatalog.section(id: "history") { header.setBadge(symbol: s.icon, tint: s.tint) }
        header.title = "Delete History"
        header.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search deletions"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        configure(batchTable, id: Self.batchCellID, scroll: batchScroll, height: 56)
        configure(fileTable, id: Self.fileCellID, scroll: fileScroll, height: 48)
        fileTable.doubleAction = #selector(revealFile)
        fileTable.target = self
        fileTable.menu = makeFileMenu()
        batchTable.menu = makeBatchMenu()

        statusLabel.font = Typography.subheadline
        statusLabel.textColor = .secondaryLabelColor
        restoreButton.isEnabled = false
        selectAllButton.isEnabled = false
        let footer = ActionBarView(leading: [refreshButton, selectAllButton, statusLabel], trailing: [restoreButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Fixed-width master (batches) + flexible detail (files). Avoids an
        // NSSplitView that, with autolayout panes, could starve the detail pane of
        // width and hide the file list entirely.
        let root = NSView()
        for v in [header, searchField, clearButton, batchScroll, fileScroll, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            // Toolbar row: search field (flexible) + Clear History (trailing).
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -Spacing.md),
            clearButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.md),

            batchScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Spacing.md),
            batchScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            batchScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Spacing.sm),
            batchScroll.widthAnchor.constraint(equalToConstant: 320),

            fileScroll.topAnchor.constraint(equalTo: batchScroll.topAnchor),
            fileScroll.leadingAnchor.constraint(equalTo: batchScroll.trailingAnchor, constant: Spacing.md),
            fileScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            fileScroll.bottomAnchor.constraint(equalTo: batchScroll.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: batchScroll.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: batchScroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: fileScroll.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: batchScroll.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: batchScroll.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: batchScroll.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: fileScroll.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: batchScroll.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    func reload() {
        entries = TrashHistory.entries()
        statusCache.removeAll()
        applyFilter()

        let totalItems = entries.reduce(0) { $0 + $1.count }
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
        header.summary = entries.isEmpty
            ? "No deletions recorded yet"
            : "\(entries.count) batch\(entries.count == 1 ? "" : "es") · \(totalItems) item\(totalItems == 1 ? "" : "s") · \(FileSize.string(totalBytes))"
        clearButton.isEnabled = !entries.isEmpty

        batchTable.reloadData()
        if !visibleEntries.isEmpty {
            batchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            clearDetail()
        }
        updateEmptyState()
    }

    /// Narrow `entries` down to the current search term (origin or any path).
    private func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { visibleEntries = entries; return }
        visibleEntries = entries.filter { e in
            e.origin.lowercased().contains(q) || e.paths.contains { $0.lowercased().contains(q) }
        }
    }

    private func clearDetail() {
        selectedFiles = []
        selectedIsLogged = false
        checkedPaths = []
        fileTable.reloadData()
        updateRestoreState()
    }

    private func updateEmptyState() {
        if entries.isEmpty {
            emptyState.isHidden = false
            emptyState.configure(symbol: "clock.arrow.circlepath",
                                 title: "No deletions recorded yet",
                                 message: "Items you move to the Trash from BetterCleaner appear here, ready to restore.")
        } else if visibleEntries.isEmpty {
            emptyState.isHidden = false
            emptyState.configure(symbol: "magnifyingglass",
                                 title: "No matches",
                                 message: "No deletions match “\(searchText)”.")
        } else {
            emptyState.isHidden = true
        }
    }

    private func configure(_ table: NSTableView, id: NSUserInterfaceItemIdentifier, scroll: NSScrollView, height: CGFloat) {
        let column = NSTableColumn(identifier: id)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = height
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
    }

    // MARK: - Status of one record

    private enum FileStatus {
        case recoverable, notRecoverable, removedFromTrash, originalExists, protected, logged
        var label: String {
            switch self {
            case .recoverable: return "In Trash"
            case .notRecoverable: return "Not recoverable"
            case .removedFromTrash: return "Emptied"
            case .originalExists: return "Original exists"
            case .protected: return "Protected"
            case .logged: return "Removed"
            }
        }
        var color: NSColor {
            switch self {
            case .recoverable: return .systemGreen
            case .originalExists: return .systemBlue
            case .protected: return .systemOrange
            case .notRecoverable, .removedFromTrash, .logged: return .secondaryLabelColor
            }
        }
        var isRestorable: Bool { self == .recoverable }
    }

    private func status(_ rec: TrashHistory.FileRecord) -> FileStatus {
        let key = rec.originalPath + "\u{0}" + (rec.trashPath ?? "")
        if let cached = statusCache[key] { return cached }
        let computed = computeStatus(rec)
        statusCache[key] = computed
        return computed
    }

    private func computeStatus(_ rec: TrashHistory.FileRecord) -> FileStatus {
        let fm = FileManager.default
        guard rec.recoverable, let trashPath = rec.trashPath else { return .notRecoverable }
        if FileMatcher.isProtected(url: URL(fileURLWithPath: rec.originalPath)) { return .protected }
        if !fm.fileExists(atPath: trashPath) { return .removedFromTrash }
        if fm.fileExists(atPath: rec.originalPath) { return .originalExists }
        return .recoverable
    }

    /// Status as shown for a row of the selected batch — logged-only batches read
    /// "Removed" regardless of per-record state.
    private func displayStatus(_ rec: TrashHistory.FileRecord) -> FileStatus {
        selectedIsLogged ? .logged : status(rec)
    }

    /// Rows to show for a batch. Real per-file records when present; otherwise
    /// synthesize non-restorable rows from `paths` so logged-only batches (Homebrew
    /// uninstall, package forget) still list what was removed instead of a blank
    /// pane.
    private func displayRecords(for entry: TrashHistory.Entry) -> [TrashHistory.FileRecord] {
        if let files = entry.files, !files.isEmpty { return files }
        return entry.paths.map { TrashHistory.FileRecord(originalPath: $0, trashPath: nil, domain: "user", recoverable: false) }
    }

    /// How many files in a batch can still be restored — drives the green count
    /// pill in the batch list so restorable batches stand out at a glance.
    private func restorableCount(in entry: TrashHistory.Entry) -> Int {
        (entry.files ?? []).filter { status($0).isRestorable }.count
    }

    private func updateRestoreState() {
        let restorablePaths = selectedFiles.filter { displayStatus($0).isRestorable }.map { $0.originalPath }
        let toRestore = restorablePaths.filter { checkedPaths.contains($0) }
        restoreButton.isEnabled = !toRestore.isEmpty
        restoreButton.title = toRestore.isEmpty ? "Restore" : "Restore (\(toRestore.count))"
        restoreButton.toolTip = restorablePaths.isEmpty ? "Nothing in this batch can be restored." : nil

        let allChecked = !restorablePaths.isEmpty && restorablePaths.allSatisfy { checkedPaths.contains($0) }
        selectAllButton.title = allChecked ? "Deselect All" : "Select All"
        selectAllButton.isEnabled = !restorablePaths.isEmpty
        statusLabel.stringValue = selectedFiles.isEmpty ? "" : "\(restorablePaths.count) of \(selectedFiles.count) restorable"
    }

    // MARK: - Actions

    @objc private func reloadClicked() { reload() }

    @objc private func searchChanged() {
        searchText = searchField.stringValue
        applyFilter()
        batchTable.reloadData()
        if !visibleEntries.isEmpty {
            batchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            clearDetail()
        }
        updateEmptyState()
    }

    private var selectedEntry: TrashHistory.Entry? {
        let row = batchTable.selectedRow
        guard row >= 0, row < visibleEntries.count else { return nil }
        return visibleEntries[row]
    }

    @objc private func selectAllToggle() {
        let restorablePaths = selectedFiles.filter { displayStatus($0).isRestorable }.map { $0.originalPath }
        let allChecked = !restorablePaths.isEmpty && restorablePaths.allSatisfy { checkedPaths.contains($0) }
        if allChecked { restorablePaths.forEach { checkedPaths.remove($0) } }
        else { restorablePaths.forEach { checkedPaths.insert($0) } }
        fileTable.reloadData()
        updateRestoreState()
    }

    @objc private func clearHistoryClicked() {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear Delete History?"
        alert.informativeText = "This removes the record of past deletions. Files already in the Trash are not affected and can still be restored from the Trash."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TrashHistory.clear()
        searchField.stringValue = ""
        searchText = ""
        reload()
    }

    @objc private func deleteBatchClicked() {
        let row = batchTable.clickedRow
        guard row >= 0, row < visibleEntries.count else { return }
        TrashHistory.remove(id: visibleEntries[row].id)
        reload()
    }

    @objc private func restoreSelected() {
        let toRestore = selectedFiles.filter { displayStatus($0).isRestorable && checkedPaths.contains($0.originalPath) }
        performRestore(toRestore)
    }

    @objc private func restoreOneClicked() {
        let row = fileTable.clickedRow
        guard row >= 0, row < selectedFiles.count else { return }
        let rec = selectedFiles[row]
        guard displayStatus(rec).isRestorable else { NSSound.beep(); return }
        performRestore([rec])
    }

    private func performRestore(_ files: [TrashHistory.FileRecord]) {
        guard !files.isEmpty else { NSSound.beep(); return }
        let needsAdmin = files.contains { $0.domain == "system" }

        let alert = NSAlert()
        alert.messageText = "Restore \(files.count) item\(files.count == 1 ? "" : "s")?"
        alert.informativeText = needsAdmin
            ? "Files move from the Trash back to their original locations. System files require an admin password."
            : "Files move from the Trash back to their original locations."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreButton.isEnabled = false
        loadingView.startIndeterminate("Restoring…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TrashRestorer.restore(files)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.reload()
                if result.cancelled && result.restored.isEmpty { return }
                if !result.failed.isEmpty {
                    let a = NSAlert()
                    a.messageText = "Some Items Couldn't Be Restored"
                    a.informativeText = "\(result.restored.count) restored, \(result.failed.count) failed."
                    a.runModal()
                }
            }
        }
    }

    /// Reveal the row's file in Finder — the Trash copy if it's still there,
    /// otherwise a re-created original. Driven by double-click or the context menu.
    @objc private func revealFile() {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard row >= 0, row < selectedFiles.count else { return }
        let rec = selectedFiles[row]
        let fm = FileManager.default
        if let trashPath = rec.trashPath, fm.fileExists(atPath: trashPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
        } else if fm.fileExists(atPath: rec.originalPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.originalPath)])
        } else {
            NSSound.beep()
        }
    }

    @objc private func copyFilePath() {
        let row = fileTable.clickedRow
        guard row >= 0, row < selectedFiles.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedFiles[row].originalPath, forType: .string)
    }

    private func toggleFile(_ path: String, on: Bool) {
        if on { checkedPaths.insert(path) } else { checkedPaths.remove(path) }
        updateRestoreState()
    }

    // MARK: - Context menus

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Restore This", action: #selector(restoreOneClicked), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyFilePath), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func makeBatchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete from History", action: #selector(deleteBatchClicked), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(restoreOneClicked):
            let row = fileTable.clickedRow
            guard row >= 0, row < selectedFiles.count else { return false }
            return displayStatus(selectedFiles[row]).isRestorable
        case #selector(revealFile), #selector(copyFilePath):
            return fileTable.clickedRow >= 0 && fileTable.clickedRow < selectedFiles.count
        case #selector(deleteBatchClicked):
            return batchTable.clickedRow >= 0 && batchTable.clickedRow < visibleEntries.count
        default:
            return true
        }
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === batchTable ? visibleEntries.count : selectedFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === batchTable {
            let cell = batchTable.makeView(withIdentifier: Self.batchCellID, owner: self) as? HistoryBatchCell
                ?? HistoryBatchCell(id: Self.batchCellID)
            let entry = visibleEntries[row]
            cell.configure(origin: entry.origin,
                           detail: "\(friendlyDate(entry.date)) · \(entry.count) item\(entry.count == 1 ? "" : "s") · \(FileSize.string(entry.bytes))",
                           restorable: restorableCount(in: entry))
            return cell
        }
        let cell = fileTable.makeView(withIdentifier: Self.fileCellID, owner: self) as? HistoryFileCell
            ?? HistoryFileCell(id: Self.fileCellID)
        let rec = selectedFiles[row]
        let st = displayStatus(rec)
        cell.configure(icon: IconCache.icon(forPath: rec.trashPath ?? rec.originalPath),
                       name: (rec.originalPath as NSString).lastPathComponent,
                       path: (rec.originalPath as NSString).abbreviatingWithTildeInPath,
                       statusText: st.label,
                       statusColor: st.color,
                       checkable: st.isRestorable,
                       checked: checkedPaths.contains(rec.originalPath))
        cell.fullPath = rec.originalPath
        cell.onToggle = { [weak self] on in self?.toggleFile(rec.originalPath, on: on) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === batchTable }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === batchTable else { return }
        let entry = selectedEntry
        selectedIsLogged = (entry?.files?.isEmpty ?? true)
        selectedFiles = entry.map { displayRecords(for: $0) } ?? []
        // Default to every restorable file checked.
        checkedPaths = Set(selectedFiles.filter { displayStatus($0).isRestorable }.map { $0.originalPath })
        fileTable.reloadData()
        updateRestoreState()
    }
}

// MARK: - Cells

/// A removal batch: tinted circular badge, origin title, friendly date/size
/// subtitle, and a green "N" pill counting how many files can still be restored.
private final class HistoryBatchCell: NSTableCellView {
    private let badge = NSImageView()
    private let badgeBG = NSView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let countPill = PillLabel()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        badgeBG.translatesAutoresizingMaskIntoConstraints = false
        badgeBG.wantsLayer = true
        badgeBG.layer?.cornerRadius = 16
        badgeBG.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        badge.contentTintColor = .controlAccentColor
        badge.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        title.font = Typography.medium(.body)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Typography.caption
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [badgeBG, badge, textStack, countPill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            badgeBG.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            badgeBG.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBG.widthAnchor.constraint(equalToConstant: 32),
            badgeBG.heightAnchor.constraint(equalToConstant: 32),
            badge.centerXAnchor.constraint(equalTo: badgeBG.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeBG.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: badgeBG.trailingAnchor, constant: Spacing.sm),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: countPill.leadingAnchor, constant: -Spacing.sm),

            countPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            countPill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        countPill.setContentHuggingPriority(.required, for: .horizontal)
        countPill.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(origin: String, detail: String, restorable: Int) {
        title.stringValue = origin
        subtitle.stringValue = detail
        if restorable > 0 {
            countPill.isHidden = false
            countPill.configure(text: "\(restorable)", color: .systemGreen)
            countPill.toolTip = "\(restorable) item\(restorable == 1 ? "" : "s") can be restored"
        } else {
            countPill.isHidden = true
        }
    }
}

/// A single removed file: restore checkbox, file icon, name + path, status pill.
private final class HistoryFileCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let pill = PillLabel()

    var onToggle: ((Bool) -> Void)?
    var fullPath: String? { didSet { subtitle.toolTip = fullPath } }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        checkbox.target = self
        checkbox.action = #selector(toggled)
        iconView.imageScaling = .scaleProportionallyDown
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Typography.caption
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [checkbox, iconView, textStack, pill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.listIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.listIconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -Spacing.sm),

            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(icon: NSImage?, name: String, path: String, statusText: String, statusColor: NSColor, checkable: Bool, checked: Bool) {
        iconView.image = icon
        title.stringValue = name
        subtitle.stringValue = path
        pill.configure(text: statusText, color: statusColor)
        // Only restorable files are checkable; others read as a disabled, unchecked
        // box so it's clear they can't be brought back.
        checkbox.isEnabled = checkable
        checkbox.state = (checkable && checked) ? .on : .off
    }

    @objc private func toggled() { onToggle?(checkbox.state == .on) }
}

/// A small rounded status capsule: tinted background + coloured text.
private final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.medium(.caption1)
        label.alignment = .center
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }
}
