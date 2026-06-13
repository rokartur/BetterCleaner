import AppKit

/// The detail pane: an outline of leftover files grouped by category, each row a
/// checkbox + file, with a header (title/summary) and footer (select-all,
/// selected total, Move to Trash). Drives `Trasher` and reports rescans.
@MainActor
final class FileListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {

    /// Re-run the current scan after a successful trash (so removed rows vanish).
    /// Only used now for a *complete uninstall* (the app bundle is gone, so the
    /// app list must reload). Plain trashes/prunes update the model in place via
    /// `removeTrashedItems` — no disk re-walk, no app-list reload.
    var onRescanRequested: (() -> Void)?

    /// Fired after an in-place removal with the new visible reclaimable total, so
    /// the owning section can refresh its sidebar size without re-scanning.
    var onReclaimableChanged: ((Int64) -> Void)?

    /// When set (via `enableAssignToApp`), the row context menu offers "Assign to
    /// App…", calling this with the files to attribute. Only the Orphaned list
    /// wires it — every other list keeps the plain reveal-only menu.
    private var onAssignToApp: (([URL]) -> Void)?

    /// When set, "Move to Trash" performs a *complete* uninstall of this app
    /// (quit, unload daemons, reset privacy, forget receipts, Keychain) via
    /// `AppRemover`, not just a file trash. Nil for orphan/junk lists, which keep
    /// the plain `Trasher` path. Also gates the per-app "Prune Languages" button.
    var uninstallContext: InstalledApp? {
        didSet {
            pruneLanguagesButton.isHidden = (uninstallContext == nil)
            // A per-app list runs the *full* uninstall (quit/unload/TCC/receipts/
            // Keychain), so the destructive button must say "Uninstall…" — the
            // plain "Move to Trash" label dangerously understates it.
            trashButton.title = (uninstallContext != nil) ? "Uninstall…" : "Move to Trash"
            // Applications detail shows the real app icon as the header badge;
            // junk/orphan/dev lists keep their gradient section badge (set via
            // `setSectionBadge`), so only override when an app is in context.
            if let app = uninstallContext {
                header.setBadge(appIcon: IconCache.icon(forPath: app.url.path))
            } else if oldValue != nil {
                header.clearBadge()
            }
        }
    }

    /// The section's gradient badge (Junk / Orphaned / Development), set by the
    /// owning wrapper from `NavCatalog` so the header matches the sidebar.
    func setSectionBadge(symbol: String, tint: NSColor) {
        header.setBadge(symbol: symbol, tint: tint)
    }

    /// Add an "Assign to App…" row context-menu item that calls `handler` with the
    /// files to attribute. Used only by the Orphaned list to attribute leftovers to
    /// an installed app. Operates on every checked (ticked) row at once, so several
    /// files/folders can be assigned in one step; falls back to the right-clicked
    /// row when it sits outside the checked set (Finder-style selection semantics).
    func enableAssignToApp(_ handler: @escaping ([URL]) -> Void) {
        onAssignToApp = handler
        outlineView.menu?.addItem(.separator())
        let item = NSMenuItem(title: "Assign to App…", action: #selector(assignClickedRow), keyEquivalent: "")
        item.target = self
        outlineView.menu?.addItem(item)
    }

    /// A collapsible cluster of deeply-nested sibling files (e.g. the 17
    /// `com.apple.sharedfilelist/…/*.sfl4` recent-document fragments), shown as
    /// one tidy row instead of a wall of near-identical entries. Selection lives
    /// on the leaf `FileItem`s; the group is display-only.
    private final class GroupNode {
        let title: String
        var items: [FileItem]
        init(title: String, items: [FileItem]) {
            self.title = title
            self.items = items
        }
        var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
        var allSelected: Bool { !items.isEmpty && items.allSatisfy { $0.isSelected } }
        /// Green dot only when every file in the cluster is auto-selectable.
        var allSafe: Bool { items.allSatisfy { $0.isAutoSelectable } }
    }

    private final class SectionNode {
        let category: String
        /// Display rows: each is a `FileItem` (leaf) or a `GroupNode`.
        var entries: [Any]
        /// All leaf items in this section (flattened across groups).
        let items: [FileItem]
        init(category: String, items: [FileItem]) {
            self.category = category
            self.items = items
            self.entries = SectionNode.group(items)
        }
        var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
        /// Green dot only when every file in the category is auto-selectable.
        var allSafe: Bool { items.allSatisfy { $0.isAutoSelectable } }

        /// Collapse runs of ≥4 siblings that live in the same deeply-nested
        /// container into a single `GroupNode`; everything else stays a leaf.
        private static func group(_ items: [FileItem]) -> [Any] {
            var byParent: [String: [FileItem]] = [:]
            for item in items {
                byParent[item.url.deletingLastPathComponent().path, default: []].append(item)
            }
            let collapsed = Set(byParent.filter { key, list in
                list.count >= 4 && isNestedContainer(key)
            }.keys)

            var entries: [Any] = []
            var emitted = Set<String>()
            for item in items {
                let parent = item.url.deletingLastPathComponent().path
                if collapsed.contains(parent) {
                    if emitted.insert(parent).inserted {
                        entries.append(GroupNode(title: prettyName(forParent: parent), items: byParent[parent]!))
                    }
                } else {
                    entries.append(item)
                }
            }
            return entries
        }

        /// A directory more than one level below its `Library` root — i.e. a real
        /// nested container, not a top-level Library subdir like `Preferences`.
        private static func isNestedContainer(_ path: String) -> Bool {
            let comps = (path as NSString).pathComponents
            guard let idx = comps.lastIndex(of: "Library") else { return false }
            return comps.count - idx - 1 > 1
        }

        private static func prettyName(forParent path: String) -> String {
            let last = (path as NSString).lastPathComponent
            if last.contains("ApplicationRecentDocuments") { return "Recent Documents" }
            if last.hasPrefix("com.apple.LSSharedFileList") { return "Shared File Lists" }
            return last
        }
    }

    /// Full result set — the source of truth for selection, totals, Select-Safe
    /// and Move to Trash. Survives search so filtering never changes what a trash
    /// actually removes.
    private var allNodes: [SectionNode] = []
    /// The filtered subset actually shown in the outline. Equals `allNodes` when
    /// the search box is empty (or disabled).
    private var nodes: [SectionNode] = []
    /// Current search text. Empty → no filtering.
    private var searchQuery = ""
    /// Whether this list offers a search box (opt-in via `enableSearch`).
    private var searchEnabled = false

    private let header = PageHeaderView()
    private let searchField = NSSearchField()
    private let legend = SafetyLegendView()
    private let outlineView = NoAnimationOutlineView()
    private let scrollView = ConditionalScrollView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "macwindow")
    private lazy var selectAllButton = Buttons.secondary("Select Safe", target: self, action: #selector(toggleSelectAll))
    private lazy var pruneLanguagesButton = Buttons.secondary("Prune Languages", target: self, action: #selector(pruneLanguages))
    private let footerLabel = NSTextField(labelWithString: "")
    private let footerSizeLabel = NSTextField(labelWithString: "")
    private lazy var trashButton = Buttons.destructive("Move to Trash", target: self, action: #selector(trashSelected))

    override func loadView() {
        let root = NSView()

        // Header
        header.translatesAutoresizingMaskIntoConstraints = false

        // Outline
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        // `.inset` insets rows from the rounded content card edge. There's no
        // row-selection conflict — the outline returns false from shouldSelectItem.
        outlineView.style = .inset
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.usesAutomaticRowHeights = false
        // Single-click anywhere on a row (or double-click, or right-click → Reveal
        // in Finder) shows the file in Finder. The checkbox is an NSButton, so it
        // consumes its own clicks and never triggers the reveal.
        outlineView.target = self
        outlineView.action = #selector(revealClickedRow)
        outlineView.doubleAction = #selector(revealClickedRow)
        let menu = NSMenu()
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealClickedRow), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
        outlineView.menu = menu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        // The list sits flat on the window surface (no card) — native, like
        // Finder / System Settings. The scroll view draws no background, so the
        // outline reads directly on the content background.

        // Empty state + shared loading overlay (EmptyStateView self-styles).

        // Footer (glass action bar). Buttons are built via the shared `Buttons`
        // factory so Trash reads as destructive (red) and the others as neutral.
        pruneLanguagesButton.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        pruneLanguagesButton.imagePosition = .imageLeading
        pruneLanguagesButton.isHidden = (uninstallContext == nil)
        pruneLanguagesButton.toolTip = "Remove this app's extra language files, keeping your preferred languages."
        footerLabel.font = Typography.subheadline
        footerLabel.textColor = .secondaryLabelColor
        footerSizeLabel.font = Typography.monospacedDigit(.subheadline, weight: .semibold)
        footerSizeLabel.textColor = .labelColor
        trashButton.isEnabled = false
        let footer = ActionBarView(leading: [selectAllButton, pruneLanguagesButton, footerLabel, footerSizeLabel], trailing: [trashButton])
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Live filter box. Opt-in (`enableSearch`) — hidden until a section turns
        // it on and there are results to filter. Sends its action on each
        // keystroke (sendsWholeSearchString = false) for incremental filtering.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .large
        searchField.placeholderString = "Search…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.isHidden = true

        // Header + search + safety legend stack vertically; NSStackView collapses
        // the legend/search when hidden (no results), so the header sits alone
        // exactly as before. Legend + search start hidden until a non-empty list.
        legend.isHidden = true
        let topStack = NSStackView(views: [header, searchField, legend])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = Spacing.sm
        topStack.translatesAutoresizingMaskIntoConstraints = false

        for v in [topStack, scrollView, footer, emptyState, loadingView] { root.addSubview(v) }

        NSLayoutConstraint.activate([
            // Pin to the safe area, not root.topAnchor — the window is
            // .fullSizeContentView with a unified toolbar, so root.topAnchor sits
            // *behind* the toolbar and the header text would render under the
            // toolbar buttons. The safe area already excludes titlebar+toolbar.
            topStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Spacing.md),
            topStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            topStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            // Stretch the header to the full stack width so its trailing badge /
            // truncation behaves as it did when pinned directly to the root.
            header.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 280),

            scrollView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: Spacing.md),
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A section's scan can finish while this detail view is still off-screen:
        // the launch "Scan all" pass (MainWindowController.scheduleInitialScan)
        // populates Junk / Orphaned / Development before the user ever opens those
        // pages. Those off-screen `showResults` calls set `nodes` but reloaded the
        // outline against a not-yet-wired dataSource (loadView sets it), so the rows
        // never built — and `startIfNeeded` won't re-scan once `hasScanned` is set.
        // Reload now that the dataSource is live so the cached results appear instead
        // of a blank pane or the old app-list placeholder. No placeholder default is
        // shown here: the Applications page sets its own via MainSplitViewController,
        // and section pages drive their own loading/results state.
        outlineView.reloadData()
        for node in nodes { outlineView.expandItem(node) }
    }

    // MARK: - Public API

    /// Show a loading state. `determinate` swaps the spinning indicator for a
    /// progress bar + percent that `updateProgress(_:)` drives.
    func showLoading(_ message: String, determinate: Bool = false) {
        allNodes = []
        nodes = []
        outlineView.reloadData()
        header.title = ""
        header.summary = ""
        legend.isHidden = true
        searchField.isHidden = true
        emptyState.isHidden = true
        if determinate {
            loadingView.startDeterminate(message)
        } else {
            loadingView.startIndeterminate(message)
        }
        updateFooter()
    }

    /// Drive the determinate bar (0…1).
    func updateProgress(_ fraction: Double) {
        loadingView.update(fraction)
    }

    private func hideProgress() {
        loadingView.stop()
    }

    func showResults(_ sections: [ScanSection], title: String, subtitle: String) {
        hideProgress()
        allNodes = sections.map { SectionNode(category: $0.category, items: $0.items) }
        header.title = title
        header.summary = subtitle
        // Empty-result copy; the search-filtered "no matches" copy is set in
        // `reloadFiltered` only when results exist but the query hides them all.
        if allNodes.isEmpty {
            emptyState.configure(symbol: "checkmark.circle",
                                 title: "No leftover files found.",
                                 message: "This app didn't leave anything behind.")
        }
        // Show the box once there's something to filter; keep any existing query.
        searchField.isHidden = !searchEnabled || allNodes.isEmpty
        reloadFiltered()
        updateFooter()
    }

    /// Turn on the live search box for this list, with a section-specific
    /// placeholder. Opt-in: only Development / System Junk / Orphaned call it.
    func enableSearch(placeholder: String) {
        searchEnabled = true
        searchField.placeholderString = placeholder
        searchField.isHidden = allNodes.isEmpty
    }

    func showPlaceholder(_ message: String) {
        hideProgress()
        allNodes = []
        nodes = []
        outlineView.reloadData()
        header.title = ""
        header.summary = ""
        legend.isHidden = true
        searchField.isHidden = true
        emptyState.configure(symbol: "macwindow", title: message)
        emptyState.isHidden = false
        updateFooter()
    }

    // MARK: - Search

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue
        reloadFiltered()
    }

    /// Rebuild `nodes` from `allNodes` honoring the current query, then reload the
    /// outline and reconcile the legend / empty-state. Selection and totals live
    /// on `allNodes`, so filtering is purely visual.
    private func reloadFiltered() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            nodes = allNodes
        } else {
            nodes = allNodes.compactMap { node in
                // A category-name match shows the whole section; otherwise filter
                // to the rows whose name or path contains the query.
                if node.category.lowercased().contains(q) {
                    return SectionNode(category: node.category, items: node.items)
                }
                let matched = node.items.filter {
                    $0.displayName.lowercased().contains(q) || $0.path.lowercased().contains(q)
                }
                return matched.isEmpty ? nil : SectionNode(category: node.category, items: matched)
            }
        }

        if allNodes.isEmpty {
            // Caller already configured the empty-state copy.
            emptyState.isHidden = false
            legend.isHidden = true
        } else if nodes.isEmpty {
            // Results exist but the query hid them all.
            emptyState.configure(symbol: "magnifyingglass",
                                 title: "No matches",
                                 message: "No files match “\(searchField.stringValue)”.")
            emptyState.isHidden = false
            legend.isHidden = true
        } else {
            emptyState.isHidden = true
            legend.isHidden = false
        }

        outlineView.reloadData()
        for node in nodes { outlineView.expandItem(node) }
    }

    /// Remove just-trashed rows from the model in place — no disk re-scan and no
    /// app-list reload. The already-scanned data is the cache; a delete drops only
    /// what's gone, keeping the rest of the list (and scroll position) intact, then
    /// reports the new total so the sidebar size updates.
    func removeTrashedItems(_ trashed: [URL]) {
        let gone = Set(trashed.map { $0.standardizedFileURL.path })
        guard !gone.isEmpty else { return }
        let before = allNodes.reduce(0) { $0 + $1.items.count }
        allNodes = allNodes.compactMap { node in
            let remaining = node.items.filter { !gone.contains($0.url.standardizedFileURL.path) }
            return remaining.isEmpty ? nil : SectionNode(category: node.category, items: remaining)
        }
        let after = allNodes.reduce(0) { $0 + $1.items.count }
        // Nothing visible changed (e.g. an Applications-tab language prune removes
        // in-bundle .lproj files, which this list never shows) — leave the header,
        // footer and sidebar untouched so we don't clobber the app-detail header.
        guard after != before else { return }

        if allNodes.isEmpty {
            // Clear the stale "N items · size" so it doesn't sit above "All clear".
            header.summary = ""
            searchField.isHidden = true
            emptyState.configure(symbol: "checkmark.circle", title: "All clear",
                                 message: "Everything you removed was moved to the Trash.")
        } else {
            // Refresh the subtitle totals the old full-rescan path used to set.
            let bytes = allNodes.flatMap { $0.items }.reduce(0) { $0 + $1.size }
            header.summary = "\(after) item\(after == 1 ? "" : "s") · \(FileSize.string(bytes))"
        }
        // reloadFiltered reconciles the outline, legend and empty-state honoring
        // any active search query.
        reloadFiltered()
        updateFooter()
        // Match the sidebar basis: only auto-selectable ("safe") bytes count as
        // reclaimable, same as each section's post-scan `onReclaimable`.
        let reclaimable = allNodes.flatMap { $0.items }.filter { $0.isAutoSelectable }.reduce(0) { $0 + $1.size }
        onReclaimableChanged?(reclaimable)
    }

    // MARK: - Footer

    private var selectedItems: [FileItem] { allNodes.flatMap { $0.items }.filter { $0.isSelected } }

    private func updateFooter() {
        let selected = selectedItems
        let bytes = selected.reduce(0) { $0 + $1.size }
        if selected.isEmpty {
            // Surface the safety promise when there's nothing selected, instead of
            // a bare "No items selected".
            footerLabel.stringValue = "Everything goes to the Trash — fully restorable"
            footerSizeLabel.isHidden = true
            footerSizeLabel.stringValue = ""
        } else {
            footerLabel.stringValue = "\(selected.count) selected ·"
            footerSizeLabel.isHidden = false
            footerSizeLabel.stringValue = FileSize.string(bytes)
        }
        trashButton.isEnabled = !selected.isEmpty
        // "Select Safe" only ever toggles auto-selectable (green-dot) rows;
        // ask-first / low-confidence items stay manual. The honest label tells the
        // user exactly that — to grab everything, they use the section checkbox.
        // Operates on the full set, not the search-filtered view.
        let autoItems = allNodes.flatMap { $0.items }.filter { $0.isAutoSelectable }
        selectAllButton.isEnabled = !autoItems.isEmpty
        selectAllButton.title = (!autoItems.isEmpty && autoItems.allSatisfy { $0.isSelected }) ? "Deselect Safe" : "Select Safe"
    }

    /// Reload cell contents (e.g. after a checkbox change) without disturbing the
    /// user's expand/collapse state. Capturing the expanded items before
    /// `reloadData()` and restoring exactly those — rather than expanding every
    /// section — is what stops a collapsed group from springing open when its
    /// checkbox is toggled.
    private func reloadPreservingExpansion() {
        let expandedSections = nodes.filter { outlineView.isItemExpanded($0) }
        let expandedGroups = nodes
            .flatMap { $0.entries }
            .compactMap { $0 as? GroupNode }
            .filter { outlineView.isItemExpanded($0) }

        outlineView.reloadData()

        for section in expandedSections { outlineView.expandItem(section) }
        for group in expandedGroups { outlineView.expandItem(group) }
    }

    @objc private func toggleSelectAll() {
        let autoItems = allNodes.flatMap { $0.items }.filter { $0.isAutoSelectable }
        guard !autoItems.isEmpty else { return }
        let selectAll = !autoItems.allSatisfy { $0.isSelected }
        for item in autoItems { item.isSelected = selectAll }
        reloadPreservingExpansion()
        updateFooter()
    }

    /// Reveal the double/right-clicked row in Finder. For a leaf it selects the
    /// file/folder; for a collapsed group it opens the containing directory.
    @objc private func revealClickedRow() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        let url: URL?
        switch item {
        case let file as FileItem: url = file.url
        case let group as GroupNode: url = group.items.first?.url.deletingLastPathComponent()
        default: url = nil // section header — nothing to reveal
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hand the files to attribute to the assign handler (Orphaned list). Operates
    /// on the *checked* (ticked) rows so several files/folders can be assigned to one
    /// app at once; right-clicking a row outside the checked set targets just that
    /// row instead (Finder-style: a click outside the selection acts on the clicked
    /// item, a click inside it acts on the whole selection).
    @objc private func assignClickedRow() {
        let urls = assignTargets()
        guard !urls.isEmpty else { NSSound.beep(); return }
        onAssignToApp?(urls)
    }

    /// The files "Assign to App…" should attribute, given the right-clicked row and
    /// the current checkbox selection. System-domain files are excluded — a per-app
    /// force-include rule can't surface them (LeftoverScanner ignores force-include
    /// for `.system`), so assigning one would silently drop it from every list
    /// instead of attributing. Groups and section headers carry no single file, so
    /// a right-click on one falls through to the checked set.
    private func assignTargets() -> [URL] {
        let clicked = outlineView.item(atRow: outlineView.clickedRow) as? FileItem
        let checked = allNodes.flatMap { $0.items }.filter { $0.isSelected }

        let targets: [FileItem]
        if let clicked, !clicked.isSelected {
            // Right-clicked a row outside the checked set → just that row.
            targets = [clicked]
        } else if !checked.isEmpty {
            // Clicked within the checked set (or on a group/header) → all checked.
            targets = checked
        } else if let clicked {
            targets = [clicked]
        } else {
            targets = []
        }
        return targets.filter { $0.domain != .system }.map { $0.url }
    }

    /// Gray out "Assign to App…" when nothing assignable is targeted, and reflect
    /// the count ("Assign 3 Items to App…") so the action never silently no-ops.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(assignClickedRow) else { return true }
        let urls = assignTargets()
        menuItem.title = urls.count > 1 ? "Assign \(urls.count) Items to App…" : "Assign to App…"
        return !urls.isEmpty
    }

    // MARK: - Prune languages (per-app)

    /// Scan the currently-shown app for removable `.lproj` localizations and,
    /// after confirmation, move them to the Trash — keeping the user's preferred
    /// languages. Only available when a specific app is shown (`uninstallContext`).
    @objc private func pruneLanguages() {
        guard let app = uninstallContext else { return }
        pruneLanguagesButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keep = LocalizationPruner.keepCodes()
            let sections = LocalizationPruner.scan(apps: [app], keep: keep)
            let items = sections.flatMap { $0.items }
            let bytes = items.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pruneLanguagesButton.isEnabled = true
                self.confirmAndPrune(app: app, items: items, bytes: bytes)
            }
        }
    }

    private func confirmAndPrune(app: InstalledApp, items: [FileItem], bytes: Int64) {
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Languages to Prune"
            alert.informativeText = "\(app.name) has no extra language files to remove."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Prune languages from \(app.name)?"
        alert.informativeText = "Remove \(items.count) language folder\(items.count == 1 ? "" : "s") · \(FileSize.string(bytes)). Your preferred languages are kept. Items go to the Trash (restorable)."
        alert.addButton(withTitle: "Prune")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Off the main thread — a root-owned language folder would otherwise block
        // the UI on the admin prompt.
        loadingView.startIndeterminate("Pruning languages…")
        pruneLanguagesButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Trasher.trash(items, origin: "\(app.name) — Languages")
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.pruneLanguagesButton.isEnabled = true
                if outcome.cancelled && outcome.trashed.isEmpty { return }
                if !outcome.failed.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some Languages Couldn't Be Removed"
                    alert.informativeText = "\(outcome.trashed.count) removed, \(outcome.failed.count) failed (permission denied or in use)."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                self.removeTrashedItems(outcome.trashed)
            }
        }
    }

    @objc private func trashSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { NSSound.beep(); return }
        if let app = uninstallContext {
            runCompleteUninstall(app: app, selected: selected)
        } else {
            runPlainTrash(selected)
        }
    }

    private func runPlainTrash(_ selected: [FileItem]) {
        if Preferences.shared.confirmBeforeDelete {
            let bytes = selected.reduce(0) { $0 + $1.size }
            let alert = NSAlert()
            alert.messageText = "Move \(selected.count) item\(selected.count == 1 ? "" : "s") to the Trash?"
            alert.informativeText = "Total size: \(FileSize.string(bytes)). Items can be restored from the Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let origin = uninstallContext?.name ?? (header.title.isEmpty ? "BetterCleaner" : header.title)
        // Trasher may spawn a blocking admin prompt for root-owned files; run it off
        // the main thread so the window stays responsive.
        loadingView.startIndeterminate("Moving to Trash…")
        trashButton.isEnabled = false
        selectAllButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Trasher.trash(selected, origin: origin)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.trashButton.isEnabled = true
                self.selectAllButton.isEnabled = true
                if outcome.cancelled && outcome.trashed.isEmpty { return }
                if !outcome.failed.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some Items Couldn't Be Removed"
                    alert.informativeText = "\(outcome.trashed.count) moved to Trash, \(outcome.failed.count) failed (permission denied or in use)."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                self.removeTrashedItems(outcome.trashed)
            }
        }
    }

    // MARK: - Complete uninstall

    private func runCompleteUninstall(app: InstalledApp, selected: [FileItem]) {
        let options = AppRemover.Options(
            quit: true,
            forceKill: Preferences.shared.completeUninstallForceQuit,
            unloadLaunchItems: true,
            resetTCC: Preferences.shared.completeUninstallResetPrivacy,
            forgetReceipts: true,
            keychain: Preferences.shared.completeUninstallKeychain
        )

        if Preferences.shared.confirmBeforeDelete {
            let bytes = selected.reduce(0) { $0 + $1.size }
            let alert = NSAlert()
            alert.messageText = "Completely uninstall \(app.name)?"
            alert.informativeText = uninstallDisclosure(selected: selected, bytes: bytes, options: options)
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let allItems = allNodes.flatMap { $0.items }
        let plan = AppRemover.Plan(app: app, items: allItems, options: options)

        header.title = ""
        header.summary = ""
        loadingView.startIndeterminate("Uninstalling \(app.name)…")
        trashButton.isEnabled = false
        selectAllButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = AppRemover.uninstall(plan) { step in
                DispatchQueue.main.async { self?.loadingView.setMessage("Uninstalling \(app.name) — \(step.title)…") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingView.stop()
                self.presentUninstallSummary(app: app, summary: summary)
                self.onRescanRequested?()
            }
        }
    }

    /// Human-readable list of everything a complete uninstall will do, for the
    /// confirmation alert.
    private func uninstallDisclosure(selected: [FileItem], bytes: Int64, options: AppRemover.Options) -> String {
        var extras = ["quit the app", "unload background items"]
        if options.forceKill { extras.append("stop helper processes") }
        if options.forgetReceipts { extras.append("forget package receipts") }
        if options.resetTCC { extras.append("reset privacy permissions") }
        if options.keychain { extras.append("remove Keychain items") }
        return """
        \(selected.count) item\(selected.count == 1 ? "" : "s") · \(FileSize.string(bytes)) → Trash (restorable).
        Will also: \(extras.joined(separator: ", ")).
        """
    }

    private func presentUninstallSummary(app: InstalledApp, summary: AppRemover.Summary) {
        // Only interrupt on a problem; success is shown by the rescan emptying.
        guard summary.cancelled || !summary.failed.isEmpty else { return }
        let alert = NSAlert()
        if summary.cancelled {
            alert.messageText = "Uninstall Cancelled"
            alert.informativeText = "\(summary.trashed.count) item\(summary.trashed.count == 1 ? "" : "s") removed before you cancelled the admin prompt."
        } else {
            alert.messageText = "Some Items Couldn't Be Removed"
            alert.informativeText = "\(summary.trashed.count) removed, \(summary.failed.count) failed (permission denied or in use)."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        if let node = item as? SectionNode { return node.entries.count }
        if let group = item as? GroupNode { return group.items.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return nodes[index] }
        if let node = item as? SectionNode { return node.entries[index] }
        return (item as! GroupNode).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SectionNode || item is GroupNode
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is SectionNode { return Metrics.headerRowHeight }
        if item is GroupNode { return Metrics.compactRowHeight }
        return Metrics.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? SectionNode {
            let cell = outlineView.makeView(withIdentifier: SectionCellView.identifier, owner: self) as? SectionCellView ?? {
                let c = SectionCellView()
                c.identifier = SectionCellView.identifier
                return c
            }()
            let checked = !node.items.isEmpty && node.items.allSatisfy { $0.isSelected }
            cell.configure(title: node.category,
                           detail: "\(node.items.count) · \(FileSize.string(node.totalSize))",
                           checked: checked,
                           enabled: !node.items.isEmpty,
                           allSafe: node.allSafe)
            cell.onToggle = { [weak self] on in
                guard let self else { return }
                // A deliberate click on the category checkbox selects/deselects
                // *every* item in it, including review-only ones (Spotlight,
                // low-confidence orphans). That's the user's explicit choice — the
                // "never auto-select" rule only governs automatic/bulk selection
                // (the footer Select-All still touches auto-selectable items only).
                for item in node.items { item.isSelected = on }
                self.reloadPreservingExpansion()
                self.updateFooter()
            }
            return cell
        }

        if let group = item as? GroupNode {
            let cell = outlineView.makeView(withIdentifier: GroupCellView.identifier, owner: self) as? GroupCellView ?? {
                let c = GroupCellView()
                c.identifier = GroupCellView.identifier
                return c
            }()
            cell.configure(title: group.title,
                           detail: "\(group.items.count) items · \(FileSize.string(group.totalSize))",
                           checked: group.allSelected,
                           allSafe: group.allSafe)
            cell.onToggle = { [weak self] on in
                // Manual group toggle selects every file in the cluster.
                for child in group.items { child.isSelected = on }
                self?.reloadPreservingExpansion()
                self?.updateFooter()
            }
            return cell
        }

        let item = item as! FileItem
        let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: self) as? FileCell ?? {
            let c = FileCell()
            c.identifier = FileCell.identifier
            return c
        }()
        cell.configure(item: item)
        cell.onToggle = { [weak self] in
            // Refresh so any enclosing group checkbox reflects the new state.
            self?.reloadPreservingExpansion()
            self?.updateFooter()
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
    }
}

/// An outline view with expand/collapse animation suppressed. User clicks on the
/// disclosure triangle route through `expandItem`/`collapseItem`, so forcing a
/// zero-duration animation context here makes both programmatic and interactive
/// toggling snap open/closed instantly.
final class NoAnimationOutlineView: NSOutlineView {
    override func expandItem(_ item: Any?, expandChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: expandChildren)
        NSAnimationContext.endGrouping()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
    }
}
