import AppKit
import BetterSettings

/// Settings pane for user-defined matching rules (the condition builder). Lists
/// each rule with an enable toggle and a human-readable sentence; Add/Edit/Remove
/// open a `ConditionEditorViewController` sheet. Rules persist to `Preferences`
/// and apply to the next per-app scan.
final class ConditionsSettingsViewController: SettingsTabViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var rules: [UserCondition] = []
    private var apps: [InstalledApp] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private static let cellID = NSUserInterfaceItemIdentifier("RuleCell")

    override func setupContent() {
        rules = Preferences.shared.userConditions

        let section = addSection(title: "Matching Rules", anchor: "rules")
        addRow(to: section, icon: "exclamationmark.shield",
               title: "Custom include / exclude rules",
               subtitle: "Refine which files an app scan surfaces. Protected system files are never affected, and included files are never auto-selected.")
        section.addContent(makeRulesView())

        // Installed apps power the per-app scope picker; load off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppFinder.installedApps(extraRoots: Preferences.shared.extraScanURLs)
            DispatchQueue.main.async { self?.apps = apps }
        }
        updateButtons()
    }

    private func makeRulesView() -> NSView {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        let addButton = NSButton(title: "Add Rule…", target: self, action: #selector(addRule))
        addButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelected)
        editButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addButton, editButton, removeButton, spacer])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 150),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Mutations

    private func persist() {
        Preferences.shared.userConditions = rules
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        removeButton.isEnabled = hasSelection
    }

    @objc private func addRule() {
        let editor = ConditionEditorViewController(apps: apps)
        editor.onSave = { [weak self] rule in
            guard let self else { return }
            self.rules.append(rule)
            self.persist()
            self.tableView.reloadData()
            self.updateButtons()
        }
        presentAsSheet(editor)
    }

    @objc private func editSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < rules.count else { return }
        let editor = ConditionEditorViewController(existing: rules[row], apps: apps)
        editor.onSave = { [weak self] rule in
            guard let self, row < self.rules.count else { return }
            self.rules[row] = rule
            self.persist()
            self.tableView.reloadData()
        }
        presentAsSheet(editor)
    }

    @objc private func removeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < rules.count else { return }
        rules.remove(at: row)
        persist()
        tableView.reloadData()
        updateButtons()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < rules.count else { return }
        rules[row].enabled = sender.state == .on
        persist()
        tableView.reloadData()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? RuleCell ?? RuleCell()
        let rule = rules[row]
        cell.checkbox.state = rule.enabled ? .on : .off
        cell.checkbox.tag = row
        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggleEnabled(_:))
        cell.label.stringValue = rule.sentence
        cell.label.textColor = rule.enabled ? .labelColor : .tertiaryLabelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}

private final class RuleCell: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("RuleCell")
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        addSubview(checkbox)
        addSubview(label)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
