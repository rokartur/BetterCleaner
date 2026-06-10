import AppKit

/// Master-detail view of `TrashHistory`: removal batches on the left, the files
/// of the selected batch on the right (with per-file restore checkboxes and a
/// colour-coded status pill), and a Restore button that moves the checked,
/// recoverable files back to their original locations. Follows the shared content
/// scaffold: page header (+ badge), flat lists, a glass action bar, and shared
/// empty/loading states.
@MainActor
final class DeleteHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var entries: [TrashHistory.Entry] = []
    private var selectedFiles: [TrashHistory.FileRecord] = []
    /// Original paths the user has ticked for restore (defaults to every
    /// restorable file in the selected batch). Reset on each batch selection.
    private var checkedPaths: Set<String> = []

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

        configure(batchTable, id: Self.batchCellID, scroll: batchScroll, height: 56)
        configure(fileTable, id: Self.fileCellID, scroll: fileScroll, height: 48)
        fileTable.doubleAction = #selector(revealFile)
        fileTable.target = self

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

            batchScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),

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
            checkedPaths = []
            fileTable.reloadData()
            updateRestoreState()
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
        case recoverable, notRecoverable, removedFromTrash, originalExists, protected
        var label: String {
            switch self {
            case .recoverable: return "In Trash"
            case .notRecoverable: return "Not recoverable"
            case .removedFromTrash: return "Emptied"
            case .originalExists: return "Original exists"
            case .protected: return "Protected"
            }
        }
        var color: NSColor {
            switch self {
            case .recoverable: return .systemGreen
            case .originalExists: return .systemBlue
            case .protected: return .systemOrange
            case .notRecoverable, .removedFromTrash: return .secondaryLabelColor
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

    /// How many files in a batch can still be restored — drives the green count
    /// pill in the batch list so restorable batches stand out at a glance.
    private func restorableCount(in entry: TrashHistory.Entry) -> Int {
        (entry.files ?? []).filter { status($0).isRestorable }.count
    }

    private func updateRestoreState() {
        let toRestore = selectedFiles.filter { status($0).isRestorable && checkedPaths.contains($0.originalPath) }
        let restorableTotal = selectedFiles.filter { status($0).isRestorable }.count
        restoreButton.isEnabled = !toRestore.isEmpty
        restoreButton.title = toRestore.isEmpty ? "Restore" : "Restore (\(toRestore.count))"
        restoreButton.toolTip = restorableTotal == 0 ? "Nothing in this batch can be restored." : nil
        statusLabel.stringValue = selectedFiles.isEmpty ? "" : "\(restorableTotal) of \(selectedFiles.count) restorable"
    }

    // MARK: - Actions

    @objc private func reloadClicked() { reload() }

    private var selectedEntry: TrashHistory.Entry? {
        let row = batchTable.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    @objc private func restoreSelected() {
        let toRestore = selectedFiles.filter { status($0).isRestorable && checkedPaths.contains($0.originalPath) }
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

    private func toggleFile(_ path: String, on: Bool) {
        if on { checkedPaths.insert(path) } else { checkedPaths.remove(path) }
        updateRestoreState()
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === batchTable ? entries.count : selectedFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === batchTable {
            let cell = batchTable.makeView(withIdentifier: Self.batchCellID, owner: self) as? HistoryBatchCell
                ?? HistoryBatchCell(id: Self.batchCellID)
            let entry = entries[row]
            cell.configure(origin: entry.origin,
                           detail: "\(friendlyDate(entry.date)) · \(entry.count) item\(entry.count == 1 ? "" : "s") · \(FileSize.string(entry.bytes))",
                           restorable: restorableCount(in: entry))
            return cell
        }
        let cell = fileTable.makeView(withIdentifier: Self.fileCellID, owner: self) as? HistoryFileCell
            ?? HistoryFileCell(id: Self.fileCellID)
        let rec = selectedFiles[row]
        let st = status(rec)
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
        selectedFiles = selectedEntry?.files ?? []
        // Default to every restorable file checked.
        checkedPaths = Set(selectedFiles.filter { status($0).isRestorable }.map { $0.originalPath })
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

        for v in [badgeBG, badge, textStack, countPill] { addSubview(v) }
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
