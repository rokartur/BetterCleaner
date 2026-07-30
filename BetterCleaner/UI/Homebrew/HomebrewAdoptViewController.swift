import AppKit

/// Adopts one manually-installed app at a time. Suggested and manually entered casks
/// are both validated against the app artifact before Homebrew is allowed to run.
@MainActor
final class HomebrewAdoptViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    private let onChanged: () -> Void
    private var candidates: [HomebrewAdopter.Candidate] = []
    private var suggestions: [String: HomebrewAdopter.Match] = [:]
    private var selectionGeneration = 0

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "wand.and.stars")
    private let caskField = NSComboBox()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Select an app to find matching casks.")
    private lazy var adoptButton = Buttons.primary("Adopt", target: self, action: #selector(adopt))
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
        let subtitle = NSTextField(wrappingLabelWithString: "Choose an app, then select a matching cask or enter its full token manually.")
        subtitle.font = Typography.footnote
        subtitle.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Metrics.rowHeight
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        caskField.placeholderString = "Cask token, e.g. firefox or user/tap/cask"
        caskField.completes = true
        caskField.numberOfVisibleItems = 8
        caskField.delegate = self
        caskField.target = self
        caskField.action = #selector(caskSelectionChanged)
        caskField.translatesAutoresizingMaskIntoConstraints = false

        let caskLabel = NSTextField(labelWithString: "Cask")
        caskLabel.font = Typography.subheadline
        caskLabel.setContentHuggingPriority(.required, for: .horizontal)
        let caskRow = NSStackView(views: [caskLabel, caskField])
        caskRow.orientation = .horizontal
        caskRow.alignment = .centerY
        caskRow.spacing = Spacing.sm

        statusLabel.font = Typography.footnote
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        let selectionStack = NSStackView(views: [caskRow, statusLabel])
        selectionStack.orientation = .vertical
        selectionStack.alignment = .leading
        selectionStack.spacing = Spacing.xs
        selectionStack.translatesAutoresizingMaskIntoConstraints = false
        caskRow.widthAnchor.constraint(equalTo: selectionStack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: selectionStack.widthAnchor).isActive = true

        adoptButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, closeButton, adoptButton])
        footer.orientation = .horizontal
        footer.spacing = Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false

        let head = NSStackView(views: [title, subtitle])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = Spacing.xs
        head.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for item in [head, scrollView, selectionStack, footer, emptyState, loadingView] { root.addSubview(item) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 600),
            root.heightAnchor.constraint(equalToConstant: 520),

            head.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: head.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            selectionStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.md),
            selectionStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            selectionStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.topAnchor.constraint(equalTo: selectionStack.bottomAnchor, constant: Spacing.md),
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
        selectionGeneration += 1
        candidates = []
        tableView.reloadData()
        clearCaskSelection("Select an app to find matching casks.")
        emptyState.isHidden = true
        loadingView.startIndeterminate("Scanning applications…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewAdopter.candidates() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                guard case .success(let found) = result else {
                    if case .failure(let error) = result {
                        self.emptyState.isHidden = false
                        self.emptyState.configure(symbol: "exclamationmark.triangle",
                                                  title: "Couldn't scan apps",
                                                  message: error.localizedDescription,
                                                  actionTitle: "Retry", action: { [weak self] in self?.scan() })
                    }
                    return
                }
                self.candidates = found
                self.emptyState.isHidden = !found.isEmpty
                if found.isEmpty {
                    self.emptyState.configure(symbol: "checkmark.seal",
                                              title: "Nothing to adopt",
                                              message: "Every discovered app is already managed by Homebrew.")
                }
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? HomebrewRowCell ?? HomebrewRowCell()
        let candidate = candidates[row]
        let subtitle = candidate.app.shortVersion.map { "Version \($0)" } ?? candidate.appPath
        cell.configure(icon: NSWorkspace.shared.icon(forFile: candidate.appPath),
                       title: candidate.appName, subtitle: subtitle,
                       badgeText: nil, badgeColor: .clear)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadSuggestions()
    }

    private var selectedCandidate: HomebrewAdopter.Candidate? {
        let row = tableView.selectedRow
        return row >= 0 && row < candidates.count ? candidates[row] : nil
    }

    private func loadSuggestions() {
        selectionGeneration += 1
        let generation = selectionGeneration
        adoptButton.title = "Adopt"
        guard let candidate = selectedCandidate else {
            clearCaskSelection("Select an app to find matching casks.")
            return
        }

        clearCaskSelection("Searching Homebrew casks…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewAdopter.suggestions(for: candidate.app) }
            DispatchQueue.main.async {
                guard let self, generation == self.selectionGeneration,
                      self.selectedCandidate?.app.id == candidate.app.id else { return }
                switch result {
                case .success(let matches):
                    self.suggestions = Dictionary(matches.map { ($0.package.commandToken, $0) },
                                                  uniquingKeysWith: { first, _ in first })
                    self.caskField.addItems(withObjectValues: matches.map(\.package.commandToken))
                    if let first = matches.first {
                        self.caskField.stringValue = first.package.commandToken
                        self.show(first)
                    } else {
                        self.setStatus("No exact artifact match found. Enter the cask token manually.")
                    }
                case .failure(let error):
                    self.setStatus("Couldn't load suggestions: \(error.localizedDescription)", color: .systemRed)
                }
                self.updateAdoptButton()
            }
        }
    }

    // MARK: - Cask selection

    @objc private func caskSelectionChanged() { updateCaskStatus() }

    func comboBoxSelectionDidChange(_ notification: Notification) { updateCaskStatus() }

    func controlTextDidChange(_ obj: Notification) { updateCaskStatus() }

    private func updateCaskStatus() {
        selectionGeneration += 1
        adoptButton.title = "Adopt"
        let token = caskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = suggestions[token] {
            show(match)
        } else if !token.isEmpty {
            setStatus("The manual token will be validated before adoption.")
        } else {
            setStatus("Select a suggested cask or enter its token manually.")
        }
        updateAdoptButton()
    }

    private func show(_ match: HomebrewAdopter.Match) {
        let version = match.package.latestVersion.isEmpty ? "unknown version" : "version \(match.package.latestVersion)"
        if match.versionCompatible {
            setStatus("\(match.package.displayName), \(version) — exact app artifact match.")
        } else {
            setStatus("\(match.package.displayName), \(version) — version differs; confirmation required.", color: .systemOrange)
        }
    }

    private func clearCaskSelection(_ message: String) {
        suggestions = [:]
        caskField.removeAllItems()
        caskField.stringValue = ""
        setStatus(message)
        updateAdoptButton()
    }

    private func setStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    private func updateAdoptButton() {
        adoptButton.isEnabled = selectedCandidate != nil
            && !caskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    @objc private func adopt() {
        guard let candidate = selectedCandidate else { return }
        let token = caskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let generation = selectionGeneration

        adoptButton.isEnabled = false
        adoptButton.title = "Validating…"
        setStatus("Validating \(token)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewAdopter.validateManualToken(token, for: candidate.app) }
            DispatchQueue.main.async {
                guard let self, self.selectionGeneration == generation,
                      self.selectedCandidate?.app.id == candidate.app.id,
                      self.caskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == token else { return }
                self.adoptButton.title = "Adopt"
                self.updateAdoptButton()
                switch result {
                case .success(let match):
                    guard match.versionCompatible || self.confirmVersionMismatch(match, app: candidate.app) else { return }
                    self.runAdoption(match, candidate: candidate)
                case .failure(let error):
                    self.setStatus(error.localizedDescription, color: .systemRed)
                }
            }
        }
    }

    private func confirmVersionMismatch(_ match: HomebrewAdopter.Match, app: InstalledApp) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Versions don't match"
        alert.informativeText = "The installed app reports \(app.shortVersion ?? "an unknown version"), while \(match.package.displayName) reports \(match.package.latestVersion.isEmpty ? "an unknown version" : match.package.latestVersion). Homebrew will still verify that the existing artifact is identical."
        alert.addButton(withTitle: "Try to Adopt")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runAdoption(_ match: HomebrewAdopter.Match, candidate: HomebrewAdopter.Candidate) {
        let sheet = HomebrewProgressViewController(
            title: "Adopting \(candidate.appName)…",
            arguments: HomebrewActions.adoptArgs(tokens: [match.package.commandToken])
        ) { [weak self] success in
            guard success, let self else { return }
            self.onChanged()
            self.candidates.removeAll { $0.app.id == candidate.app.id }
            self.tableView.reloadData()
            self.clearCaskSelection(self.candidates.isEmpty
                ? "Every discovered app is already managed by Homebrew."
                : "Select another app to adopt.")
            self.emptyState.isHidden = !self.candidates.isEmpty
            if self.candidates.isEmpty {
                self.emptyState.configure(symbol: "checkmark.seal", title: "Nothing to adopt",
                                          message: "Every discovered app is already managed by Homebrew.")
            }
        }
        presentAsSheet(sheet)
    }

    @objc private func closeSheet() { dismiss(self) }
}
