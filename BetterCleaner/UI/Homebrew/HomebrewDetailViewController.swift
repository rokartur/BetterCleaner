import AppKit

/// Detail pane for the Homebrew page, styled 1:1 after TapHouse: a hero icon tile +
/// big name + "version · Type", an Overview / Dependencies tab strip, then sectioned
/// content (Description, an Information key/value grid, inline Actions). Services and
/// taps reuse the same hero + Information + Actions layout without tabs.
///
/// Package mutations run in a streaming `HomebrewProgressViewController` sheet; quick
/// service/tap commands run inline. `onChanged` fires after any mutation.
@MainActor
final class HomebrewDetailViewController: NSViewController {
    var onChanged: (() -> Void)?

    private enum Selection {
        case empty
        case package(HomebrewPackage)
        case service(ServiceInfo)
        case tap(TapInfo)
    }
    private var selection: Selection = .empty
    private var dependents: [String] = []
    private var depTree = ""
    private var sizeText = ""
    private var zapEnabled = false

    private enum Tab: Int { case overview, dependencies }
    private var tab: Tab = .overview

    // Header (fixed, above the scroll).
    private let heroTile = IconTileView(size: 60, corner: 14)
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleIcon = NSImageView()
    private let subtitleField = NSTextField(labelWithString: "")
    private let headerDivider = NSBox()
    private let tabs = NSSegmentedControl(labels: ["Overview", "Dependencies"],
                                          trackingMode: .selectOne, target: nil, action: nil)

    private let contentScroll = NSScrollView()
    private let contentStack = NSStackView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "cup.and.saucer")

    private var headerStack: NSStackView!

    // MARK: - Layout

    override func loadView() {
        titleField.font = .systemFont(ofSize: 26, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail

        subtitleIcon.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        subtitleIcon.contentTintColor = .tertiaryLabelColor
        subtitleIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        subtitleIcon.setContentHuggingPriority(.required, for: .horizontal)
        subtitleField.font = Typography.subheadline
        subtitleField.textColor = .secondaryLabelColor

        let subtitleRow = NSStackView(views: [subtitleIcon, subtitleField])
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = 5

        let titleColumn = NSStackView(views: [titleField, subtitleRow])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 4

        headerStack = NSStackView(views: [heroTile, titleColumn])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = Spacing.md
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Spacing.lg
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: Spacing.md),
            contentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Spacing.md),
        ])
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentScroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
        ])

        let root = NSView()
        for v in [headerStack!, headerDivider, tabs, contentScroll, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.lg),

            headerDivider.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: Spacing.md),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            tabs.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: Spacing.md),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            contentScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Spacing.md),
            contentScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            contentScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.lg),

            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
        ])
        view = root
        showPlaceholder()
    }

    // MARK: - Public entry

    func show(_ selection: HomebrewSelection?) {
        dependents = []; depTree = ""; sizeText = ""; zapEnabled = false; tab = .overview
        tabs.selectedSegment = 0
        guard let selection else { self.selection = .empty; showPlaceholder(); return }
        switch selection {
        case .package(let p): self.selection = .package(p); showPackage(p)
        case .service(let s): self.selection = .service(s); showService(s)
        case .tap(let t):     self.selection = .tap(t);     showTap(t)
        }
    }

    private func showPlaceholder() {
        loadingView.stop()
        setChromeHidden(true)
        emptyState.configure(symbol: "cup.and.saucer",
                             title: "Select an item",
                             message: "Choose a package, service, or tap to manage it.")
        emptyState.isHidden = false
    }

    private func setChromeHidden(_ hidden: Bool) {
        headerStack.isHidden = hidden
        headerDivider.isHidden = hidden
        contentScroll.isHidden = hidden
        if hidden { tabs.isHidden = true }
    }

    // MARK: - Package

    private func showPackage(_ p: HomebrewPackage) {
        emptyState.isHidden = true
        setChromeHidden(false)
        tabs.isHidden = false

        if let icon = appIcon(for: p) { heroTile.setAppIcon(icon) }
        else { heroTile.setGlyph(p.isCask ? "macwindow" : "terminal", color: .systemBlue) }
        titleField.stringValue = p.displayName
        subtitleField.stringValue = "\(p.installedVersion) · \(p.isCask ? "Cask" : "Formula")"

        renderTabContent()

        // Load size + dependency info off the main thread, then re-render.
        let token = p.token, isCask = p.isCask
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = HomebrewService.installedSize(p)
            let tree = isCask ? "" : HomebrewService.dependencyTree(token: token)
            let usedBy = isCask ? [] : HomebrewService.usedBy(token: token)
            DispatchQueue.main.async {
                guard let self, case .package(let current) = self.selection, current.token == token else { return }
                self.sizeText = size ?? ""
                self.depTree = tree
                self.dependents = usedBy
                self.renderTabContent()
            }
        }
    }

    @objc private func tabChanged() {
        tab = Tab(rawValue: tabs.selectedSegment) ?? .overview
        renderTabContent()
    }

    private func renderTabContent() {
        guard case .package(let p) = selection else { return }
        clearSections()
        switch tab {
        case .overview:
            if !p.description.isEmpty { addSection("Description", wrapLabel(p.description)) }
            addSection("Information", kvGrid(packageInfoPairs(p)))
            addSection("Actions", packageActions(p))
        case .dependencies:
            if !p.dependencies.isEmpty {
                addSection("Dependencies", wrapLabel(p.dependencies.joined(separator: ", ")))
            }
            if !dependents.isEmpty {
                let label = wrapLabel(dependents.joined(separator: ", "))
                addSection("Required by", label)
            }
            if !depTree.isEmpty { addSection("Dependency tree", monoLabel(depTree)) }
            if p.dependencies.isEmpty && dependents.isEmpty && depTree.isEmpty {
                addSection("Dependencies", wrapLabel("No dependencies."))
            }
        }
    }

    private func packageInfoPairs(_ p: HomebrewPackage) -> [KeyValueView] {
        var kv: [KeyValueView] = [
            KeyValueView(key: "Version", value: p.installedVersion.isEmpty ? "—" : p.installedVersion),
        ]
        if !p.homepage.isEmpty {
            kv.append(KeyValueView(key: "Homepage", value: shortHost(p.homepage), link: true) { [weak self] in self?.openHomepage() })
        }
        kv.append(KeyValueView(key: "Type", value: p.isCask ? "Cask" : "Formula (CLI)"))
        if !sizeText.isEmpty { kv.append(KeyValueView(key: "Size", value: sizeText)) }
        if !p.isCask {
            kv.append(KeyValueView(key: "Installed as", value: p.installedOnRequest ? "Direct install" : "Dependency"))
        }
        if !p.tap.isEmpty { kv.append(KeyValueView(key: "Tap", value: p.tap)) }
        return kv
    }

    private func packageActions(_ p: HomebrewPackage) -> NSView {
        var buttons: [NSView] = []
        if p.isOutdated {
            buttons.append(actionButton("Upgrade", "arrow.up.circle", #selector(upgrade)))
        }
        if !p.isCask {
            buttons.append(actionButton(p.isPinned ? "Unpin" : "Pin", p.isPinned ? "pin.slash" : "pin", #selector(pin)))
        }
        buttons.append(actionButton("Uninstall", "trash", #selector(uninstall)))

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.sm

        guard p.isCask else { return row }
        // Casks get a zap toggle above the buttons.
        let zap = NSButton(checkboxWithTitle: "Also remove all related files (zap)", target: self, action: #selector(zapToggled(_:)))
        zap.state = zapEnabled ? .on : .off
        let col = NSStackView(views: [zap, row])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = Spacing.sm
        return col
    }

    private func appIcon(for p: HomebrewPackage) -> NSImage? {
        guard p.isCask else { return nil }
        let path = "/Applications/\(p.displayName).app"
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    // MARK: - Service

    private func showService(_ s: ServiceInfo) {
        emptyState.isHidden = true
        setChromeHidden(false)
        tabs.isHidden = true
        heroTile.setGlyph("gearshape.2", color: s.isRunning ? .systemGreen : .systemGray)
        titleField.stringValue = s.name
        subtitleField.stringValue = "Service · \(s.status.capitalized)"

        clearSections()
        var kv: [KeyValueView] = [KeyValueView(key: "Status", value: s.status.capitalized)]
        if let user = s.user, !user.isEmpty { kv.append(KeyValueView(key: "User", value: user)) }
        if let file = s.file, !file.isEmpty { kv.append(KeyValueView(key: "File", value: file)) }
        addSection("Information", kvGrid(kv))

        let buttons: [NSView] = s.isRunning
            ? [actionButton("Stop", "stop.circle", #selector(stopService)),
               actionButton("Restart", "arrow.clockwise.circle", #selector(restartService))]
            : [actionButton("Start", "play.circle", #selector(startService))]
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal; row.spacing = Spacing.sm
        addSection("Actions", row)
    }

    // MARK: - Tap

    private func showTap(_ t: TapInfo) {
        emptyState.isHidden = true
        setChromeHidden(false)
        tabs.isHidden = true
        heroTile.setGlyph("arrow.triangle.branch", color: .systemBlue)
        titleField.stringValue = t.name
        subtitleField.stringValue = "Tap · \(t.packageCount) package\(t.packageCount == 1 ? "" : "s")"

        clearSections()
        var kv: [KeyValueView] = [KeyValueView(key: "Official", value: (t.official ?? false) ? "Yes" : "No")]
        if let remote = t.remote, !remote.isEmpty {
            kv.append(KeyValueView(key: "Remote", value: shortHost(remote), link: remote.hasPrefix("http")) { [weak self] in self?.openHomepage() })
        }
        kv.append(KeyValueView(key: "Formulae", value: "\(t.formulaNames?.count ?? 0)"))
        kv.append(KeyValueView(key: "Casks", value: "\(t.caskTokens?.count ?? 0)"))
        addSection("Information", kvGrid(kv))

        if !(t.official ?? false) {
            let row = NSStackView(views: [actionButton("Remove Tap", "trash", #selector(untap))])
            row.orientation = .horizontal
            addSection("Actions", row)
        }
    }

    // MARK: - Actions

    @objc private func zapToggled(_ sender: NSButton) { zapEnabled = sender.state == .on }

    @objc private func upgrade() {
        guard case .package(let p) = selection else { return }
        runMutation(title: "Upgrading \(p.displayName)…", arguments: HomebrewActions.upgradeArgs(p))
    }

    @objc private func pin() {
        guard case .package(let p) = selection, !p.isCask else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(HomebrewActions.pinArgs(p))
            DispatchQueue.main.async {
                guard let self else { return }
                if !out.ok { self.alert("Couldn't \(p.isPinned ? "unpin" : "pin")", out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    @objc private func uninstall() {
        guard case .package(let p) = selection else { return }
        let zap = p.isCask && zapEnabled

        if Preferences.shared.confirmBeforeDelete {
            let alert = NSAlert()
            alert.messageText = "Uninstall “\(p.displayName)”?"
            var info = p.isCask
                ? (zap ? "Removes the cask and every file it created (zap). This can't be undone here."
                       : "Removes the cask. Some related files may remain — tick “zap” to remove everything.")
                : "Removes the formula via Homebrew."
            if !dependents.isEmpty {
                info += "\n\n⚠️ Still required by: \(dependents.joined(separator: ", ")). Removing it may break those packages."
            }
            alert.informativeText = info
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Cancel")
            if !dependents.isEmpty { alert.buttons.first?.hasDestructiveAction = true }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let name = p.displayName
        runMutation(title: "Uninstalling \(name)…", arguments: HomebrewActions.uninstallArgs(p, zap: zap)) {
            TrashHistory.recordRemoval(origin: "Homebrew: \(name)", items: [p.token], bytes: 0, at: Date())
        }
    }

    @objc private func startService()   { serviceControl(.start) }
    @objc private func stopService()    { serviceControl(.stop) }
    @objc private func restartService() { serviceControl(.restart) }

    private func serviceControl(_ action: HomebrewActions.ServiceAction) {
        guard case .service(let s) = selection else { return }
        let args = HomebrewActions.serviceArgs(action, name: s.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(args)
            DispatchQueue.main.async {
                guard let self else { return }
                if !out.ok { self.alert("Couldn't \(action.rawValue) service", out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    @objc private func untap() {
        guard case .tap(let t) = selection else { return }
        let alert = NSAlert()
        alert.messageText = "Remove tap “\(t.name)”?"
        alert.informativeText = "Untaps this repository. Installed packages from it stay; you just won't get updates from the tap."
        alert.addButton(withTitle: "Remove Tap")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let args = HomebrewActions.untapArgs(t.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(args)
            DispatchQueue.main.async {
                guard let self else { return }
                if !out.ok { self.alert("Couldn't remove tap", out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    @objc private func openHomepage() {
        let urlString: String?
        switch selection {
        case .package(let p): urlString = p.homepage
        case .tap(let t):     urlString = t.remote
        default:              urlString = nil
        }
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func runMutation(title: String, arguments: [String], onSuccess: (() -> Void)? = nil) {
        let sheet = HomebrewProgressViewController(title: title, arguments: arguments) { [weak self] success in
            if success { onSuccess?() }
            self?.onChanged?()
        }
        presentAsSheet(sheet)
    }

    // MARK: - Section building

    private func clearSections() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func addSection(_ title: String, _ body: NSView) {
        let head = NSTextField(labelWithString: title)
        head.font = Typography.semibold(.headline)
        head.textColor = .labelColor

        let container = NSStackView(views: [head, body])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = Spacing.sm
        container.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func wrapLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Typography.subheadline
        l.textColor = .secondaryLabelColor
        l.isSelectable = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func monoLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.isSelectable = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: " \(title)", target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func kvGrid(_ items: [KeyValueView]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = Spacing.lg
        col.translatesAutoresizingMaskIntoConstraints = false
        var i = 0
        while i < items.count {
            let rowItems = Array(items[i ..< min(i + 2, items.count)])
            let row = NSStackView(views: rowItems)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = Spacing.md
            row.translatesAutoresizingMaskIntoConstraints = false
            col.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            i += 2
        }
        return col
    }

    private func shortHost(_ urlString: String) -> String {
        guard var host = URL(string: urlString)?.host else { return urlString }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
