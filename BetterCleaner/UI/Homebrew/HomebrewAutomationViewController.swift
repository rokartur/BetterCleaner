import AppKit

/// Edits the single Homebrew LaunchAgent configuration. All rows share the action
/// switches at the top; each row contributes one launchd calendar interval.
@MainActor
final class HomebrewAutomationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var configuration = HomebrewAutomation.load()

    private let enabledCheck = NSButton(checkboxWithTitle: "Enable automatic maintenance", target: nil, action: nil)
    private let updateCheck = NSButton(checkboxWithTitle: "Update Homebrew", target: nil, action: nil)
    private let upgradeCheck = NSButton(checkboxWithTitle: "Upgrade packages (don't quit running apps)", target: nil, action: nil)
    private let greedyCheck = NSButton(checkboxWithTitle: "Include self-updating and latest casks", target: nil, action: nil)
    private let cleanupCheck = NSButton(checkboxWithTitle: "Autoremove and clean cache", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView(symbol: "calendar.badge.plus")
    private lazy var addButton = Buttons.secondary("Add", target: self, action: #selector(addSchedule))
    private lazy var editButton = Buttons.secondary("Edit", target: self, action: #selector(editSchedule))
    private lazy var deleteButton = Buttons.secondary("Delete", target: self, action: #selector(deleteSchedule))
    private lazy var logButton = Buttons.secondary("View Log", target: self, action: #selector(viewLog))
    private lazy var applyButton = Buttons.primary("Apply", target: self, action: #selector(applyChanges))

    override func loadView() {
        // The toolbar title says "Auto Update"; this header only explains behavior.
        let subtitle = NSTextField(wrappingLabelWithString: "Run Homebrew in the background on one or more schedules. "
            + "A cask that needs administrator access may show a macOS password dialog at run time.")
        subtitle.font = Typography.footnote
        subtitle.textColor = .secondaryLabelColor

        statusLabel.font = Typography.footnote
        statusLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [subtitle, enabledCheck, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Spacing.xs
        header.translatesAutoresizingMaskIntoConstraints = false

        upgradeCheck.target = self
        upgradeCheck.action = #selector(upgradeToggled)
        greedyCheck.toolTip = "Uses brew upgrade --greedy, but still refuses to quit running apps."
        let actions = NSStackView(views: [updateCheck, upgradeCheck, greedyCheck, cleanupCheck])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = Spacing.xs
        actions.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: HomebrewRowCell.identifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSchedule)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addButton, editButton, deleteButton, logButton, spacer, applyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for child in [header, actions, scrollView, emptyState, footer] { root.addSubview(child) }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.configure(symbol: "calendar.badge.plus", title: "No schedules", message: "Add a daily, weekly, or monthly maintenance time.")

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            actions.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.md),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.lg),
        ])
        view = root
        reloadControls()
    }

    private func reloadControls() {
        enabledCheck.state = configuration.isEnabled ? .on : .off
        updateCheck.state = configuration.runUpdate ? .on : .off
        upgradeCheck.state = configuration.runUpgrade ? .on : .off
        greedyCheck.state = configuration.includeAutoUpdatingCasks ? .on : .off
        greedyCheck.isEnabled = configuration.runUpgrade
        cleanupCheck.state = configuration.runCleanup ? .on : .off
        tableView.reloadData()
        emptyState.isHidden = !configuration.schedules.isEmpty
        editButton.isEnabled = tableView.selectedRow >= 0
        deleteButton.isEnabled = tableView.selectedRow >= 0
        logButton.isEnabled = FileManager.default.fileExists(atPath: HomebrewAutomation.logURL.path)

        let enabledCount = configuration.enabledSchedules.count
        let agentLoaded = HomebrewAutomation.isAgentLoaded()
        if !configuration.isEnabled {
            statusLabel.stringValue = "Disabled — schedules are preserved."
        } else if enabledCount == 0 {
            statusLabel.stringValue = "Pending — add or enable a schedule, then Apply."
        } else if !agentLoaded {
            statusLabel.stringValue = "Not active — review the schedule and click Apply."
        } else {
            statusLabel.stringValue = "\(enabledCount) active schedule\(enabledCount == 1 ? "" : "s")."
        }
    }

    private func syncConfigurationFromControls() {
        configuration.isEnabled = enabledCheck.state == .on
        configuration.runUpdate = updateCheck.state == .on
        configuration.runUpgrade = upgradeCheck.state == .on
        configuration.includeAutoUpdatingCasks = greedyCheck.state == .on
        configuration.runCleanup = cleanupCheck.state == .on
    }

    func numberOfRows(in tableView: NSTableView) -> Int { configuration.schedules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let schedule = configuration.schedules[row]
        let cell = tableView.makeView(withIdentifier: HomebrewRowCell.identifier, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        cell.configure(
            icon: NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil),
            title: schedule.frequency.rawValue,
            subtitle: description(for: schedule),
            badgeText: schedule.isEnabled ? "Enabled" : "Paused",
            badgeColor: schedule.isEnabled ? .systemGreen : .systemGray
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRow >= 0
        editButton.isEnabled = selected
        deleteButton.isEnabled = selected
    }

    @objc private func upgradeToggled() {
        greedyCheck.isEnabled = upgradeCheck.state == .on
    }

    @objc private func addSchedule() {
        syncConfigurationFromControls()
        guard let schedule = scheduleEditor(existing: nil) else { return }
        configuration.schedules.append(schedule)
        reloadControls()
        tableView.selectRowIndexes(IndexSet(integer: configuration.schedules.count - 1), byExtendingSelection: false)
    }

    @objc private func editSchedule() {
        syncConfigurationFromControls()
        let row = tableView.selectedRow
        guard configuration.schedules.indices.contains(row),
              let updated = scheduleEditor(existing: configuration.schedules[row])
        else { return }
        configuration.schedules[row] = updated
        reloadControls()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func deleteSchedule() {
        syncConfigurationFromControls()
        let row = tableView.selectedRow
        guard configuration.schedules.indices.contains(row) else { return }
        configuration.schedules.remove(at: row)
        reloadControls()
    }

    @objc private func applyChanges() {
        syncConfigurationFromControls()
        applyButton.isEnabled = false
        let pending = configuration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewAutomation.apply(pending) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyButton.isEnabled = true
                switch result {
                case .success:
                    self.configuration = HomebrewAutomation.load()
                    self.reloadControls()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func viewLog() {
        NSWorkspace.shared.open(HomebrewAutomation.logURL)
    }

    private func scheduleEditor(existing: HomebrewSchedule?) -> HomebrewSchedule? {
        let current = existing ?? defaultSchedule()
        let frequency = NSPopUpButton()
        frequency.addItems(withTitles: HomebrewScheduleFrequency.allCases.map(\.rawValue))
        frequency.selectItem(withTitle: current.frequency.rawValue)

        let weekday = NSPopUpButton()
        weekday.addItems(withTitles: Calendar.current.weekdaySymbols)
        weekday.selectItem(at: max(0, min(6, current.weekday - 1)))

        let day = NSTextField(string: "\(current.dayOfMonth)")
        day.alignment = .right

        let time = NSDatePicker()
        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = [.hourMinute]
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = current.hour
        components.minute = current.minute
        time.dateValue = Calendar.current.date(from: components) ?? Date()

        let enabled = NSButton(checkboxWithTitle: "Schedule enabled", target: nil, action: nil)
        enabled.state = current.isEnabled ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Frequency"), frequency],
            [NSTextField(labelWithString: "Weekday (weekly)"), weekday],
            [NSTextField(labelWithString: "Day 1–28 (monthly)"), day],
            [NSTextField(labelWithString: "Time"), time],
            [NSView(), enabled],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = Spacing.sm
        grid.columnSpacing = Spacing.md

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add schedule" : "Edit schedule"
        alert.accessoryView = grid
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        guard let selectedFrequency = frequency.titleOfSelectedItem.flatMap(HomebrewScheduleFrequency.init(rawValue:)),
              let dayValue = Int(day.stringValue), (1...28).contains(dayValue)
        else {
            showError("Day of month must be between 1 and 28.")
            return nil
        }
        let timeParts = Calendar.current.dateComponents([.hour, .minute], from: time.dateValue)
        var result = current
        result.frequency = selectedFrequency
        result.weekday = weekday.indexOfSelectedItem + 1
        result.dayOfMonth = dayValue
        result.hour = timeParts.hour ?? 9
        result.minute = timeParts.minute ?? 0
        result.isEnabled = enabled.state == .on
        return result
    }

    private func defaultSchedule() -> HomebrewSchedule {
        let now = Calendar.current.dateComponents([.weekday, .hour, .minute, .day], from: Date())
        return HomebrewSchedule(
            frequency: .weekly,
            weekday: now.weekday ?? 2,
            dayOfMonth: min(now.day ?? 1, 28),
            hour: now.hour ?? 9,
            minute: now.minute ?? 0
        )
    }

    private func description(for schedule: HomebrewSchedule) -> String {
        let time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
        switch schedule.frequency {
        case .daily:
            return "Every day at \(time)"
        case .weekly:
            let days = Calendar.current.weekdaySymbols
            let name = days.indices.contains(schedule.weekday - 1) ? days[schedule.weekday - 1] : "Unknown day"
            return "Every \(name) at \(time)"
        case .monthly:
            return "Day \(schedule.dayOfMonth) of every month at \(time)"
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Automatic maintenance wasn't changed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
