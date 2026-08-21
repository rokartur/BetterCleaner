import AppKit

/// The "File Search" tool: a query bar over the shared file list, so any file on
/// the Mac can be found by name (Spotlight) or by the text inside it (ripgrep),
/// then reviewed and trashed with the same controls as every scan result.
@MainActor
final class FileSearchViewController: NSViewController {
    private let fileListVC = FileListViewController()

    private let queryField = NSSearchField()
    private let matchPopUp = NSPopUpButton()
    private let kindPopUp = NSPopUpButton()
    private let sizePopUp = NSPopUpButton()
    private let datePopUp = NSPopUpButton()
    private let scopePopUp = NSPopUpButton()
    private lazy var ignoredFilesCheckbox = NSButton(
        checkboxWithTitle: "Include .gitignored files",
        target: self,
        action: #selector(filterChanged)
    )
    private lazy var searchButton = Buttons.primary("Search", target: self, action: #selector(runSearch))

    /// Minimum-size filter choices, in bytes.
    private static let sizeOptions: [(title: String, bytes: Int64)] = [
        ("Any Size", 0), ("Over 10 MB", 10_000_000), ("Over 100 MB", 100_000_000), ("Over 1 GB", 1_000_000_000),
    ]
    /// Modified-within choices, in days.
    private static let dateOptions: [(title: String, days: Int)] = [
        ("Any Date", 0), ("Last 24 Hours", 1), ("Last 7 Days", 7), ("Last 30 Days", 30), ("Last Year", 365),
    ]

    /// Cancels the in-flight search when a new one starts; a result whose token was
    /// cancelled is a stale answer and gets dropped.
    private var currentToken: ScanToken?
    /// Filter changes re-run the query only once the user has searched at all.
    private var hasSearched = false

    override func loadView() {
        let root = NSView()

        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.controlSize = .large
        queryField.target = self
        queryField.action = #selector(runSearch)
        // Whole-string: a system-wide query per keystroke is a lot of work for a
        // result the user has not finished describing.
        queryField.sendsWholeSearchString = true

        configure(matchPopUp, titles: FileSearcher.Match.allCases.map(\.title))
        configure(kindPopUp, titles: FileSearcher.Kind.allCases.map(\.title))
        configure(sizePopUp, titles: Self.sizeOptions.map(\.title))
        configure(datePopUp, titles: Self.dateOptions.map(\.title))
        configure(scopePopUp, titles: FileSearcher.Scope.allCases.map(\.title))

        let filters = NSStackView(views: [
            matchPopUp, kindPopUp, sizePopUp, datePopUp, scopePopUp, ignoredFilesCheckbox,
        ])
        filters.orientation = .horizontal
        filters.spacing = Spacing.sm

        let queryRow = NSStackView(views: [queryField, searchButton])
        queryRow.orientation = .horizontal
        queryRow.spacing = Spacing.sm
        updateControls()

        let bar = NSStackView(views: [queryRow, filters])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = Spacing.sm
        bar.translatesAutoresizingMaskIntoConstraints = false

        addChild(fileListVC)
        fileListVC.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        root.addSubview(fileListVC.view)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.md),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            queryRow.widthAnchor.constraint(equalTo: bar.widthAnchor),

            fileListVC.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            fileListVC.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileListVC.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileListVC.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fileListVC.onRescanRequested = { [weak self] in self?.runSearch() }
        showIntro()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(queryField)
    }

    private func configure(_ popUp: NSPopUpButton, titles: [String]) {
        popUp.addItems(withTitles: titles)
        popUp.target = self
        popUp.action = #selector(filterChanged)
    }

    private var criteria: FileSearcher.Criteria {
        FileSearcher.Criteria(
            text: queryField.stringValue,
            match: FileSearcher.Match.allCases[matchPopUp.indexOfSelectedItem],
            kind: FileSearcher.Kind.allCases[kindPopUp.indexOfSelectedItem],
            minSize: Self.sizeOptions[sizePopUp.indexOfSelectedItem].bytes,
            withinDays: Self.dateOptions[datePopUp.indexOfSelectedItem].days,
            scope: FileSearcher.Scope.allCases[scopePopUp.indexOfSelectedItem],
            includeIgnoredFiles: ignoredFilesCheckbox.state == .on
        )
    }

    @objc private func filterChanged() {
        updateControls()
        guard hasSearched else { return }
        runSearch()
    }

    /// Keep every control's meaning true for the selected engine: ripgrep reports
    /// files, not kinds, and only ripgrep consults ignore files.
    private func updateControls() {
        let isContentSearch = criteria.match == .contents
        queryField.placeholderString = isContentSearch
            ? "Text or regular expression inside files"
            : "File name, or a raw kMDItem… Spotlight query"
        // Reset rather than grey out a stale choice: a disabled "Images" sitting
        // above a list of .txt hits reads as a filter that was applied.
        if isContentSearch, kindPopUp.indexOfSelectedItem != 0 { kindPopUp.selectItem(at: 0) }
        kindPopUp.isEnabled = !isContentSearch
        ignoredFilesCheckbox.isHidden = !isContentSearch
    }

    @objc private func runSearch() {
        let criteria = criteria
        guard !criteria.isEmpty else {
            hasSearched = false
            showIntro()
            return
        }
        hasSearched = true

        guard criteria.match == .name || FileSearcher.ripgrepPath != nil else {
            fileListVC.showCompletion(
                title: "ripgrep Required",
                message: "Searching inside files uses ripgrep. Install it with \u{201C}brew install ripgrep\u{201D}, "
                    + "then search again.",
                symbol: "terminal"
            )
            return
        }

        // Without Full Disk Access mdfind returns a truncated index and ripgrep's
        // permission errors are swallowed by --no-messages, so an ungated search
        // would answer "nothing found" when the truth is "not allowed to look".
        guard FullDiskAccess.refresh() else {
            fileListVC.showFullDiskAccessRequired()
            return
        }

        fileListVC.showLoading(criteria.match == .contents ? "Searching file contents…" : "Searching…")
        currentToken?.cancel()
        let token = ScanToken()
        currentToken = token

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = FileSearcher.search(criteria) { token.isCancelled }
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                // Rendered against the criteria that ran, not the live controls: the
                // user can retype while a search is in flight.
                self.show(results, for: criteria)
            }
        }
    }

    private func show(_ results: FileSearcher.Results, for criteria: FileSearcher.Criteria) {
        guard !results.invalidPattern else {
            fileListVC.showCompletion(
                title: "Invalid Pattern",
                message: "ripgrep could not read \u{201C}\(criteria.trimmedText)\u{201D} as a regular expression. "
                    + "Escape the special characters, or search for a plainer piece of the text.",
                symbol: "exclamationmark.triangle"
            )
            return
        }
        guard !results.items.isEmpty else {
            showEmpty(for: criteria, stoppedEarly: results.truncated)
            return
        }
        let count = results.items.count
        let partial = results.truncated ? " (partial)" : ""
        fileListVC.showResults(
            LeftoverScanner.sections(from: results.items),
            title: "File Search",
            subtitle: "\(count) item\(count == 1 ? "" : "s")\(partial) · ",
            metric: FileSize.string(results.totalSize)
        )
    }

    /// A search that ran out of time found nothing *yet*, which is a different
    /// statement from "nothing on this Mac matches" and must not be reported as one.
    private func showEmpty(for criteria: FileSearcher.Criteria, stoppedEarly: Bool) {
        guard !stoppedEarly else {
            fileListVC.showCompletion(
                title: "Search Stopped Early",
                message: "No match yet after \(Int(FileSearcher.contentSearchTimeout)) seconds in "
                    + "\(criteria.scope.title). Add a size or date filter, or search a narrower scope.",
                symbol: "clock"
            )
            return
        }
        fileListVC.showCompletion(
            title: "No Matches",
            message: criteria.match == .contents
                ? "No file in \(criteria.scope.title) contains that text. Files over "
                    + "\(FileSearcher.maxGrepFileSizeMB) MB are skipped"
                    + (criteria.includeIgnoredFiles ? "." : ", as is anything a .gitignore excludes.")
                : "Nothing in \(criteria.scope.title) matches those filters. Spotlight skips unindexed "
                    + "volumes and most hidden system folders.",
            symbol: "magnifyingglass"
        )
    }

    private func showIntro() {
        currentToken?.cancel()
        fileListVC.showCompletion(
            title: "Search Your Mac",
            message: "Find any file by name or by the text inside it, narrowed by kind, size or date. "
                + "Results are yours to keep — nothing is pre-selected for deletion.",
            symbol: "magnifyingglass"
        )
    }
}
