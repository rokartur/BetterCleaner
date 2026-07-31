import AppKit

/// A reusable single-column list of file-system paths with Add… / Remove
/// controls, used by the Exclusions settings pane to edit a `Preferences` path
/// array. "Add…" opens an `NSOpenPanel` (directories only); double-click reveals a
/// row in Finder. `onChange` fires after every edit with the new list.
@MainActor
final class PathListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (([String]) -> Void)?

    private(set) var paths: [String]
    private let addTitle: String
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private static let cellID = NSUserInterfaceItemIdentifier("PathCell")

    init(paths: [String], addTitle: String = "Add…") {
        self.paths = paths
        self.addTitle = addTitle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.pathRowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(revealRow)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        let addButton = NSButton(title: addTitle, target: self, action: #selector(addPaths))
        addButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addButton, removeButton, spacer])
        footer.orientation = .horizontal
        footer.spacing = Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 120),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.sm),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func addPaths() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var changed = false
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !paths.contains(path) { paths.append(path); changed = true }
        }
        guard changed else { return }
        tableView.reloadData()
        onChange?(paths)
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < paths.count else { return }
        paths.remove(at: row)
        tableView.reloadData()
        updateRemoveState()
        onChange?(paths)
    }

    @objc private func revealRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < paths.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: paths[row])])
    }

    private func updateRemoveState() {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? Self.makeCell()
        let path = paths[row]
        cell.textField?.stringValue = (path as NSString).abbreviatingWithTildeInPath
        cell.textField?.toolTip = path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveState()
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.font = Typography.caption
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
