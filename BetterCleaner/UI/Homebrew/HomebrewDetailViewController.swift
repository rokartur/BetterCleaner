import AppKit

/// Detail pane for the Homebrew page. Renders whichever item the master list
/// selected — a package, a service, or a tap — TapHouse-style: a header (icon tile +
/// name + "Formula · vX"), sectioned info (Description, Information key/value grid,
/// Dependencies, Required by), and a bottom action bar.
///
/// - **Package**: Homepage, Upgrade (when outdated), Uninstall (casks offer a *zap*
///   checkbox). Formulae also show their dependency tree and warn when something
///   still depends on them.
/// - **Service**: Start / Stop / Restart.
/// - **Tap**: Homepage (remote), Remove Tap.
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
    /// Formulae that depend on the shown formula (drives the uninstall warning).
    private var dependents: [String] = []
    private var depTree = ""

    private let header = PageHeaderView(titleTruncation: .byTruncatingMiddle)
    private let contentScroll = NSScrollView()
    private let contentStack = NSStackView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "cup.and.saucer")
    private let statusLabel = NSTextField(labelWithString: "")

    private lazy var zapCheckbox: NSButton = {
        let b = NSButton(checkboxWithTitle: "Remove all related files (zap)", target: nil, action: nil)
        b.toolTip = "Also delete every file this cask ever created — a complete uninstall."
        return b
    }()
    private lazy var homepageButton = Buttons.secondary("Homepage", target: self, action: #selector(openHomepage))
    private lazy var upgradeButton = Buttons.secondary("Upgrade", target: self, action: #selector(upgrade))
    private lazy var startButton = Buttons.secondary("Start", target: self, action: #selector(startService))
    private lazy var stopButton = Buttons.secondary("Stop", target: self, action: #selector(stopService))
    private lazy var restartButton = Buttons.secondary("Restart", target: self, action: #selector(restartService))
    private lazy var uninstallButton = Buttons.destructive("Uninstall", target: self, action: #selector(uninstall))
    private lazy var untapButton = Buttons.destructive("Remove Tap", target: self, action: #selector(untap))

    // MARK: - Layout

    override func loadView() {
        header.setBadge(symbol: "cup.and.saucer.fill")
        header.translatesAutoresizingMaskIntoConstraints = false

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

        statusLabel.font = Typography.subheadline
        statusLabel.textColor = .secondaryLabelColor

        let footer = ActionBarView(
            leading: [statusLabel, zapCheckbox],
            trailing: [homepageButton, startButton, stopButton, restartButton, upgradeButton, untapButton, uninstallButton]
        )
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [header, contentScroll, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            contentScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            contentScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.topAnchor.constraint(equalTo: contentScroll.bottomAnchor, constant: Spacing.sm),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.md),

            emptyState.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),

            loadingView.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
        ])
        view = root
        showPlaceholder()
    }

    // MARK: - Public entry

    func show(_ selection: HomebrewSelection?) {
        dependents = []
        depTree = ""
        guard let selection else { self.selection = .empty; showPlaceholder(); return }
        switch selection {
        case .package(let p): self.selection = .package(p); showPackage(p)
        case .service(let s): self.selection = .service(s); showService(s)
        case .tap(let t):     self.selection = .tap(t);     showTap(t)
        }
    }

    private func showPlaceholder() {
        loadingView.stop()
        setButtons(visible: [])
        zapCheckbox.isHidden = true
        statusLabel.stringValue = ""
        header.clearBadge()
        header.title = "Homebrew"
        header.summary = ""
        header.detail = ""
        clearSections()
        emptyState.configure(symbol: "cup.and.saucer",
                             title: "Select an item",
                             message: "Choose a package, service, or tap to manage it.")
        emptyState.isHidden = false
    }

    // MARK: - Package

    private func showPackage(_ p: HomebrewPackage) {
        emptyState.isHidden = true
        if let icon = appIcon(for: p) { header.setBadge(appIcon: icon) }
        else { header.setBadge(symbol: p.isCask ? "macwindow" : "shippingbox") }
        header.title = p.displayName
        header.summary = packageSummary(p)
        header.detail = p.token == p.displayName ? "" : p.token

        zapCheckbox.state = .off
        var buttons: [NSButton] = []
        if !p.homepage.isEmpty { buttons.append(homepageButton) }
        if p.isOutdated { buttons.append(upgradeButton) }
        buttons.append(uninstallButton)
        setButtons(visible: buttons)
        zapCheckbox.isHidden = !p.isCask
        statusLabel.stringValue = ""

        renderPackage(p)

        // Formulae: load the dependency tree + reverse dependents off the main thread.
        guard !p.isCask else { return }
        let token = p.token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = HomebrewService.dependencyTree(token: token)
            let usedBy = HomebrewService.usedBy(token: token)
            DispatchQueue.main.async {
                guard let self, case .package(let current) = self.selection, current.token == token else { return }
                self.dependents = usedBy
                self.depTree = tree
                self.renderPackage(current)
            }
        }
    }

    /// (Re)build the package sections from current state — called once up front and
    /// again when the async dependency data arrives.
    private func renderPackage(_ p: HomebrewPackage) {
        clearSections()

        if !p.description.isEmpty {
            addSection("Description", wrapLabel(p.description))
        }

        var kv: [KeyValueView] = [
            KeyValueView(key: "Version", value: p.installedVersion.isEmpty ? "—" : p.installedVersion),
            KeyValueView(key: "Type", value: p.isCask ? "Cask" : "Formula"),
        ]
        if !p.latestVersion.isEmpty, p.latestVersion != p.installedVersion {
            kv.append(KeyValueView(key: p.isOutdated ? "Latest (update)" : "Latest", value: p.latestVersion))
        }
        if !p.tap.isEmpty { kv.append(KeyValueView(key: "Tap", value: p.tap)) }
        if !p.homepage.isEmpty {
            kv.append(KeyValueView(key: "Homepage", value: p.homepage, link: true) { [weak self] in self?.openHomepage() })
        }
        if !p.isCask {
            kv.append(KeyValueView(key: "Installed", value: p.installedOnRequest ? "On request" : "As a dependency"))
        }
        addSection("Information", kvGrid(kv))

        if !p.dependencies.isEmpty {
            addSection("Dependencies", wrapLabel(p.dependencies.joined(separator: ", ")))
        }
        if !dependents.isEmpty {
            let label = wrapLabel("⚠️ " + dependents.joined(separator: ", "))
            label.textColor = .systemOrange
            addSection("Required by", label)
        }
        if !depTree.isEmpty {
            addSection("Dependency tree", monoLabel(depTree))
        }
    }

    private func packageSummary(_ p: HomebrewPackage) -> String {
        var parts: [String] = [p.isCask ? "Cask" : "Formula"]
        if !p.installedVersion.isEmpty { parts.append("v\(p.installedVersion)") }
        if p.isPinned { parts.append("pinned") }
        if p.isOutdated { parts.append("update available") }
        return parts.joined(separator: "  ·  ")
    }

    private func appIcon(for p: HomebrewPackage) -> NSImage? {
        guard p.isCask else { return nil }
        let path = "/Applications/\(p.displayName).app"
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    // MARK: - Service

    private func showService(_ s: ServiceInfo) {
        emptyState.isHidden = true
        zapCheckbox.isHidden = true
        header.setBadge(symbol: "gearshape.2")
        header.title = s.name
        header.summary = "Service  ·  \(s.status.capitalized)"
        header.detail = ""
        statusLabel.stringValue = ""
        setButtons(visible: s.isRunning ? [stopButton, restartButton] : [startButton])

        clearSections()
        var kv: [KeyValueView] = [KeyValueView(key: "Status", value: s.status.capitalized)]
        if let user = s.user, !user.isEmpty { kv.append(KeyValueView(key: "User", value: user)) }
        if let file = s.file, !file.isEmpty { kv.append(KeyValueView(key: "File", value: file)) }
        addSection("Information", kvGrid(kv))
    }

    // MARK: - Tap

    private func showTap(_ t: TapInfo) {
        emptyState.isHidden = true
        zapCheckbox.isHidden = true
        header.setBadge(symbol: "arrow.triangle.branch")
        header.title = t.name
        header.summary = "Tap  ·  \(t.packageCount) package\(t.packageCount == 1 ? "" : "s")"
        header.detail = ""
        statusLabel.stringValue = ""
        var buttons: [NSButton] = []
        if (t.remote ?? "").hasPrefix("http") { buttons.append(homepageButton) }
        if !(t.official ?? false) { buttons.append(untapButton) }   // core taps can't be removed
        setButtons(visible: buttons)

        clearSections()
        var kv: [KeyValueView] = [KeyValueView(key: "Official", value: (t.official ?? false) ? "Yes" : "No")]
        if let remote = t.remote, !remote.isEmpty {
            kv.append(KeyValueView(key: "Remote", value: remote, link: remote.hasPrefix("http")) { [weak self] in self?.openHomepage() })
        }
        kv.append(KeyValueView(key: "Formulae", value: "\(t.formulaNames?.count ?? 0)"))
        kv.append(KeyValueView(key: "Casks", value: "\(t.caskTokens?.count ?? 0)"))
        addSection("Information", kvGrid(kv))

        let formulae = t.formulaNames ?? []
        let casks = t.caskTokens ?? []
        if !formulae.isEmpty { addSection("Formulae", wrapLabel(formulae.joined(separator: ", "))) }
        if !casks.isEmpty { addSection("Casks", wrapLabel(casks.joined(separator: ", "))) }
    }

    // MARK: - Section building

    private func clearSections() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func addSection(_ title: String, _ body: NSView) {
        let head = NSTextField(labelWithString: title)
        head.font = Typography.semibold(.subheadline)
        head.textColor = .secondaryLabelColor

        let container = NSStackView(views: [head, body])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = Spacing.xs
        container.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func wrapLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Typography.subheadline
        l.textColor = .labelColor
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

    /// Lay key/value cells two-per-row, columns of equal width.
    private func kvGrid(_ items: [KeyValueView]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = Spacing.md
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

    // MARK: - Package actions

    @objc private func upgrade() {
        guard case .package(let p) = selection else { return }
        runMutation(title: "Upgrading \(p.displayName)…", arguments: HomebrewActions.upgradeArgs(p))
    }

    @objc private func uninstall() {
        guard case .package(let p) = selection else { return }
        let zap = p.isCask && zapCheckbox.state == .on

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

    // MARK: - Service actions

    @objc private func startService()   { serviceControl(.start) }
    @objc private func stopService()    { serviceControl(.stop) }
    @objc private func restartService() { serviceControl(.restart) }

    private func serviceControl(_ action: HomebrewActions.ServiceAction) {
        guard case .service(let s) = selection else { return }
        setButtons(enabled: false)
        let verb: String
        switch action {
        case .start:   verb = "Starting"
        case .stop:    verb = "Stopping"
        case .restart: verb = "Restarting"
        }
        statusLabel.stringValue = "\(verb) \(s.name)…"
        let args = HomebrewActions.serviceArgs(action, name: s.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(args)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setButtons(enabled: true)
                self.statusLabel.stringValue = ""
                if !out.ok { self.alert("Couldn't \(action.rawValue) service", out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    // MARK: - Tap actions

    @objc private func untap() {
        guard case .tap(let t) = selection else { return }
        let alert = NSAlert()
        alert.messageText = "Remove tap “\(t.name)”?"
        alert.informativeText = "Untaps this repository. Installed packages from it stay; you just won't get updates from the tap."
        alert.addButton(withTitle: "Remove Tap")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setButtons(enabled: false)
        let args = HomebrewActions.untapArgs(t.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(args)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setButtons(enabled: true)
                if !out.ok { self.alert("Couldn't remove tap", out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    // MARK: - Shared

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

    /// Present the streaming progress sheet for a long mutation; on success run
    /// `onSuccess` (e.g. history bookkeeping) then refresh the list.
    private func runMutation(title: String, arguments: [String], onSuccess: (() -> Void)? = nil) {
        let sheet = HomebrewProgressViewController(title: title, arguments: arguments) { [weak self] success in
            if success { onSuccess?() }
            self?.onChanged?()
        }
        presentAsSheet(sheet)
    }

    // MARK: - Footer button management

    private func setButtons(visible: [NSButton]) {
        let all = [homepageButton, startButton, stopButton, restartButton, upgradeButton, untapButton, uninstallButton]
        for b in all {
            b.isHidden = !visible.contains(where: { $0 === b })
            b.isEnabled = true
        }
    }

    private func setButtons(enabled: Bool) {
        for b in [homepageButton, startButton, stopButton, restartButton, upgradeButton, untapButton, uninstallButton] where !b.isHidden {
            b.isEnabled = enabled
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
