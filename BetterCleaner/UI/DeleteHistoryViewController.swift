import AppKit

/// Master-detail view of `TrashHistory`: a list of removal batches on the left,
/// the files of the selected batch on the right, and a Restore button that moves
/// the recoverable ones back to their original locations. Follows the shared
/// content scaffold: page header (+ badge), elevated content cards, a glass
/// action bar, and shared empty/loading states.
@MainActor
final class DeleteHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var entries: [TrashHistory.Entry] = []
    private var selectedFiles: [TrashHistory.FileRecord] = []

    private let header = PageHeaderView()
    private let batchTable = NSTableView()
    private let fileTable = NSTableView()
    private let batchScroll = NSScrollView()
    private let fileScroll = NSScrollView()
    private lazy var refreshButton = Buttons.secondary("Refresh", target: self, action: #selector(reloadClicked))
    private lazy var restoreButton = Buttons.primary("Restore", target: self, action: #selector(restoreSelected))
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = EmptyStateView(symbol: "clock.arrow.circlepath")
    private let loadingView = LoadingStateView()

    private static let batchCellID = NSUserInterfaceItemIdentifier("BatchCell")
    private static let fileCellID = NSUserInterfaceItemIdentifier("FileRecordCell")

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override func loadView() {
        if let s = NavCatalog.section(id: "history") { header.setBadge(symbol: s.icon, tint: s.tint) }
        header.title = "Delete History"
        header.translatesAutoresizingMaskIntoConstraints = false

        configure(batchTable, id: Self.batchCellID, scroll: batchScroll)
        configure(fileTable, id: Self.fileCellID, scroll: fileScroll)
        fileTable.doubleAction = #selector(revealFile)
        fileTable.target = self

        // Two flat lists directly in the split — no cards. The scroll views draw
        // no background so each table reads on the content background.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(batchScroll)
        split.addArrangedSubview(fileScroll)

        statusLabel.font = Typography.subheadline
        statusLabel.textColor = .secondaryLabelColor
        restoreButton.isEnabled = false
        let footer = ActionBarView(leading: [refreshButton, statusLabel], trailing: [restoreButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [header, split, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.topAnchor.constraint(equalTo: split.bottomAnchor, constant: Spacing.sm),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.md),

            batchScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            emptyState.topAnchor.constraint(equalTo: split.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: split.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: split.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: split.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    func reload() {
        entries = TrashHistory.entries()
        let totalItems = entries.reduce(0) { $0 + $1.count }
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
        header.summary = entries.isEmpty
            ? "No deletions recorded yet"
            : "\(entries.count) batch\(entries.count == 1 ? "" : "es") · \(totalItems) item\(totalItems == 1 ? "" : "s") · \(FileSize.string(totalBytes))"

        emptyState.isHidden = !entries.isEmpty
        if entries.isEmpty {
            emptyState.configure(symbol: "clock.arrow.circlepath",
                                 title: "No deletions recorded yet",
                                 message: "Items you move to the Trash from BetterCleaner appear here, ready to restore.")
        }

        batchTable.reloadData()
        if !entries.isEmpty {
            batchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedFiles = []
            fileTable.reloadData()
            updateRestoreState()
        }
    }

    private func configure(_ table: NSTableView, id: NSUserInterfaceItemIdentifier, scroll: NSScrollView) {
        let column = NSTableColumn(identifier: id)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = Metrics.rowHeight
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
        case recoverable, notRecoverable, removedFromTrash, originalExists, protected
        var label: String {
            switch self {
            case .recoverable: return "In Trash"
            case .notRecoverable: return "Not recoverable"
            case .removedFromTrash: return "Emptied from Trash"
            case .originalExists: return "Original exists"
            case .protected: return "Protected"
            }
        }
        var isRestorable: Bool { self == .recoverable }
    }

    private func status(_ rec: TrashHistory.FileRecord) -> FileStatus {
        let fm = FileManager.default
        guard rec.recoverable, let trashPath = rec.trashPath else { return .notRecoverable }
        if FileMatcher.isProtected(url: URL(fileURLWithPath: rec.originalPath)) { return .protected }
        if !fm.fileExists(atPath: trashPath) { return .removedFromTrash }
        if fm.fileExists(atPath: rec.originalPath) { return .originalExists }
        return .recoverable
    }

    private func updateRestoreState() {
        let count = selectedFiles.filter { status($0).isRestorable }.count
        restoreButton.isEnabled = count > 0
        restoreButton.toolTip = count > 0 ? nil : "Nothing in this batch can be restored."
        statusLabel.stringValue = selectedFiles.isEmpty ? "" : "\(count) of \(selectedFiles.count) restorable"
    }

    // MARK: - Actions

    @objc private func reloadClicked() { reload() }

    private var selectedEntry: TrashHistory.Entry? {
        let row = batchTable.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    @objc private func restoreSelected() {
        let toRestore = selectedFiles.filter { status($0).isRestorable }
        guard !toRestore.isEmpty else { NSSound.beep(); return }
        let needsAdmin = toRestore.contains { $0.domain == "system" }

        let alert = NSAlert()
        alert.messageText = "Restore \(toRestore.count) item\(toRestore.count == 1 ? "" : "s")?"
        alert.informativeText = needsAdmin
            ? "Files move from the Trash back to their original locations. System files require an admin password."
            : "Files move from the Trash back to their original locations."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        restoreButton.isEnabled = false
        loadingView.startIndeterminate("Restoring…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TrashRestorer.restore(toRestore)
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

    @objc private func revealFile() {
        let row = fileTable.clickedRow
        guard row >= 0, row < selectedFiles.count, let trashPath = selectedFiles[row].trashPath,
              FileManager.default.fileExists(atPath: trashPath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === batchTable ? entries.count : selectedFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === batchTable {
            let cell = batchTable.makeView(withIdentifier: Self.batchCellID, owner: self) as? TwoLineCell ?? TwoLineCell(id: Self.batchCellID)
            let entry = entries[row]
            cell.title.stringValue = entry.origin
            cell.subtitle.stringValue = "\(dateFormatter.string(from: entry.date)) · \(entry.count) item\(entry.count == 1 ? "" : "s") · \(FileSize.string(entry.bytes))"
            cell.badge.stringValue = ""
            return cell
        }
        let cell = fileTable.makeView(withIdentifier: Self.fileCellID, owner: self) as? TwoLineCell ?? TwoLineCell(id: Self.fileCellID)
        let rec = selectedFiles[row]
        cell.title.stringValue = (rec.originalPath as NSString).lastPathComponent
        cell.subtitle.stringValue = (rec.originalPath as NSString).abbreviatingWithTildeInPath
        cell.subtitle.toolTip = rec.originalPath
        let st = status(rec)
        cell.badge.stringValue = st.label
        cell.badge.textColor = st.isRestorable ? .systemGreen : .secondaryLabelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { tableView === batchTable }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === batchTable else { return }
        selectedFiles = selectedEntry?.files ?? []
        fileTable.reloadData()
        updateRestoreState()
    }
}

/// Two-line cell with an optional trailing badge, used by both history tables.
private final class TwoLineCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Typography.caption
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        badge.font = Typography.caption
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title/subtitle pair vertically centered as a block; badge trailing.
        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Spacing.sm),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
