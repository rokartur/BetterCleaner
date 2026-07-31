import AppKit

/// Detail pane for the Homebrew page, styled 1:1 after TapHouse: a hero icon tile +
/// big name + "version · Type", an Overview / Dependencies tab strip, then sectioned
/// content (Description and an Information key/value grid). A shared sticky action
/// bar keeps package, service, and tap actions visible without scrolling.
///
/// Package mutations run in a streaming `HomebrewProgressViewController` sheet; quick
/// service/tap commands run inline. `onChanged` fires after any mutation.
@MainActor
final class HomebrewDetailViewController: NSViewController {
    var onChanged: (() -> Void)?

    private var selection: HomebrewSelection?
    private var dependents: [String] = []
    private var depTree = ""
    private var sizeText = ""
    private var dependencyError = ""
    private var zapEnabled = false
    private var tapInstalledIDs: Set<String> = []
    private var tapPackageRefs: [HomebrewPackageRef] = []
    private var tapPackagesLoaded = false
    private var tapPackagesError = ""
    private let tapPackagePicker = NSPopUpButton()
    private lazy var tapPackageButton = actionButton("Install", "arrow.down.circle", #selector(manageTapPackage))

    private enum Tab: Int { case overview, dependencies }
    private var tab: Tab = .overview

    // Header (fixed, above the scroll). The app-wide `PageHeaderView` — same icon
    // slot, title, summary and status-glyph treatment as every other detail pane,
    // instead of a Homebrew-only reimplementation of the same thing.
    private let header = PageHeaderView()
    private let headerDivider = NSBox()
    private let tabs = NSSegmentedControl(labels: ["Overview", "Dependencies"],
                                          trackingMode: .selectOne, target: nil, action: nil)

    /// Collapses the tab strip's row when it's hidden (services and taps have no
    /// tabs). Without it the strip keeps its intrinsic height and those panes open
    /// with a dead band between the divider and the first section.
    private var tabsHeightZero: NSLayoutConstraint!

    private let contentScroll = NSScrollView()
    private let contentStack = NSStackView()
    private let loadingView = LoadingStateView()
    private let emptyState = EmptyStateView(symbol: "cup.and.saucer")
    private let actionBar = ActionBarView()

    // MARK: - Layout

    override func loadView() {
        header.translatesAutoresizingMaskIntoConstraints = false

        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabsHeightZero = tabs.heightAnchor.constraint(equalToConstant: 0)

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
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        for childView in [header, headerDivider, tabs, contentScroll, actionBar, emptyState, loadingView] {
            root.addSubview(childView)
        }
        NSLayoutConstraint.activate([
            // Same top margin as every other detail pane (Spacing.md), so switching
            // sections doesn't nudge the title up and down.
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            tabs.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: Spacing.md),
            // Leading-aligned with the content below it. A lone centred segmented
            // control reads as a web tab bar and breaks the pane's left margin.
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),

            contentScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Spacing.md),
            contentScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            contentScroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

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
        dependents = []
        depTree = ""
        sizeText = ""
        dependencyError = ""
        zapEnabled = false
        tab = .overview
        tabs.selectedSegment = 0
        guard let selection else {
            self.selection = nil
            showPlaceholder()
            return
        }
        self.selection = selection
        switch selection {
        case .package(let package): showPackage(package)
        case .packageReference(let reference): showPackageReference(reference)
        case .service(let service): showService(service)
        case .tap(let tap): showTap(tap)
        }
    }

    private func showPlaceholder() {
        loadingView.stop()
        setChromeHidden(true)
        // A quiet hint: the list column beside this pane is where the user acts,
        // so this must not read as a second hero competing with it.
        emptyState.configure(symbol: "cup.and.saucer",
                             title: "Select an item",
                             message: "Choose a package, service, or tap to manage it.",
                             tone: .hint)
        emptyState.isHidden = false
    }

    private func setChromeHidden(_ hidden: Bool) {
        header.isHidden = hidden
        headerDivider.isHidden = hidden
        contentScroll.isHidden = hidden
        actionBar.isHidden = hidden
        if hidden { setTabsHidden(true) }
    }

    /// Hide the tab strip *and* collapse the space it reserved.
    private func setTabsHidden(_ hidden: Bool) {
        tabs.isHidden = hidden
        tabsHeightZero.isActive = hidden
    }

    // MARK: - Package

    private func showPackageReference(_ reference: HomebrewPackageRef) {
        emptyState.isHidden = true
        setChromeHidden(true)
        loadingView.startIndeterminate("Loading \(reference.token)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewService.info(reference) }
            DispatchQueue.main.async {
                guard let self,
                      case .packageReference(let current)? = self.selection,
                      current == reference else { return }
                self.loadingView.stop()
                switch result {
                case .success(let package?):
                    self.selection = .package(package)
                    self.showPackage(package)
                case .success(nil):
                    self.showPackageReferenceError("Homebrew returned no package details.", reference: reference)
                case .failure(let error):
                    self.showPackageReferenceError(error.localizedDescription, reference: reference)
                }
            }
        }
    }

    private func showPackageReferenceError(_ message: String, reference: HomebrewPackageRef) {
        emptyState.isHidden = false
        emptyState.configure(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load \(reference.token)",
            message: message,
            actionTitle: "Retry",
            action: { [weak self] in self?.showPackageReference(reference) }
        )
    }

    private func showPackage(_ package: HomebrewPackage) {
        emptyState.isHidden = true
        setChromeHidden(false)
        setTabsHidden(false)

        if let icon = appIcon(for: package) {
            header.setBadge(appIcon: icon)
        } else {
            header.setBadge(symbol: package.isCask ? "macwindow" : "terminal")
        }
        header.title = package.displayName
        let version = isInstalled(package) ? package.installedVersion : package.latestVersion
        let kind = package.isCask ? "Cask" : "Formula"
        if package.isOutdated, isInstalled(package), !package.latestVersion.isEmpty {
            // An available update is the one thing on this pane that changes what
            // the user does next, so it gets the status treatment, not a grey line.
            header.setStatus("\(version) → \(package.latestVersion) available · \(kind)",
                             symbol: "arrow.up.circle.fill",
                             tint: .systemOrange)
        } else {
            header.setSummary([version, kind].filter { !$0.isEmpty }.joined(separator: " · "))
        }

        renderTabContent()

        // Load size + dependency info off the main thread, then re-render.
        let reference = package.reference
        let isCask = package.isCask
        let installed = isInstalled(package)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = HomebrewService.installedSize(package)
            var tree = ""
            var usedBy: [String] = []
            var dependencyError = ""
            if !isCask, installed {
                do {
                    tree = try HomebrewService.dependencyTree(token: reference.token)
                    usedBy = try HomebrewService.usedBy(token: reference.token)
                } catch {
                    dependencyError = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                guard let self, case .package(let current)? = self.selection,
                      current.reference == reference else { return }
                self.sizeText = size ?? ""
                self.depTree = tree
                self.dependents = usedBy
                self.dependencyError = dependencyError
                self.renderTabContent()
            }
        }
    }

    @objc private func tabChanged() {
        tab = Tab(rawValue: tabs.selectedSegment) ?? .overview
        renderTabContent()
    }

    private func renderTabContent() {
        guard case .package(let package)? = selection else { return }
        clearSections()
        configurePackageActions(package)
        switch tab {
        case .overview:
            if package.isDisabled {
                addSection("Unavailable", warningLabel(package.disableReason.isEmpty ? "Homebrew disabled this package." : package.disableReason))
            } else if package.isDeprecated {
                addSection("Deprecated", warningLabel(package.deprecationReason.isEmpty ? "Homebrew deprecated this package." : package.deprecationReason))
            }
            if !package.description.isEmpty { addSection("Description", wrapLabel(package.description)) }
            addSection("Information", kvGrid(packageInfoPairs(package)))
            if !package.caveats.isEmpty { addSection("Caveats", monoLabel(package.caveats)) }
            if !package.requirements.isEmpty { addSection("Requirements", wrapLabel(package.requirements.joined(separator: ", "))) }
        case .dependencies:
            if !package.dependencies.isEmpty {
                addSection("Dependencies", wrapLabel(package.dependencies.joined(separator: ", ")))
            }
            if !dependents.isEmpty {
                let label = wrapLabel(dependents.joined(separator: ", "))
                addSection("Required by", label)
            }
            if !depTree.isEmpty { addSection("Dependency tree", monoLabel(depTree)) }
            if !dependencyError.isEmpty { addSection("Couldn't load dependency details", wrapLabel(dependencyError)) }
            if package.dependencies.isEmpty && dependents.isEmpty && depTree.isEmpty && dependencyError.isEmpty {
                addSection("Dependencies", wrapLabel("No dependencies."))
            }
        }
    }

    private func packageInfoPairs(_ package: HomebrewPackage) -> [KeyValueView] {
        var keyValues: [KeyValueView] = []
        if isInstalled(package) {
            keyValues.append(KeyValueView(key: "Installed", value: package.installedVersion))
        }
        if !package.latestVersion.isEmpty {
            keyValues.append(KeyValueView(key: "Latest", value: package.latestVersion))
        }
        if !package.homepage.isEmpty {
            keyValues.append(KeyValueView(key: "Homepage", value: shortHost(package.homepage), link: true) { [weak self] in
                self?.openHomepage()
            })
        }
        keyValues.append(KeyValueView(key: "Type", value: package.isCask ? "Cask" : "Formula (CLI)"))
        if !sizeText.isEmpty { keyValues.append(KeyValueView(key: "Size", value: sizeText)) }
        if !package.isCask, isInstalled(package) {
            keyValues.append(KeyValueView(
                key: "Installed as",
                value: package.installedOnRequest ? "Direct install" : "Dependency"
            ))
        }
        if !package.tap.isEmpty { keyValues.append(KeyValueView(key: "Tap", value: package.tap)) }
        if !package.license.isEmpty { keyValues.append(KeyValueView(key: "License", value: package.license)) }
        if package.autoUpdates { keyValues.append(KeyValueView(key: "Updates", value: "Managed by the app")) }
        if package.hasService { keyValues.append(KeyValueView(key: "Service", value: "Available")) }
        return keyValues
    }

    private func configurePackageActions(_ package: HomebrewPackage) {
        actionBar.isHidden = false
        actionBar.setLeading([])

        let name = package.displayName
        guard isInstalled(package) else {
            let install = configuredAction(
                Buttons.primary("Install", target: self, action: #selector(installPackage)),
                symbol: "arrow.down.circle",
                subject: name
            )
            install.isEnabled = !package.isDisabled
            actionBar.setTrailing([install])
            return
        }

        var leading: [NSView] = []
        if package.isCask {
            let zap = NSButton(
                checkboxWithTitle: "Also remove related files (zap)",
                target: self,
                action: #selector(zapToggled(_:))
            )
            zap.state = zapEnabled ? .on : .off
            zap.toolTip = "Also remove \(name)'s settings, caches and support files, not just the app."
            zap.setAccessibilityLabel("Also remove \(name)'s related files")
            zap.setAccessibilityHelp("Removes settings, caches and support files as well as the app.")
            leading.append(zap)
        }

        var trailing: [NSView] = [
            configuredAction(
                Buttons.secondary(package.isPinned ? "Unpin" : "Pin", target: self, action: #selector(pin)),
                symbol: package.isPinned ? "pin.slash" : "pin",
                subject: name
            )
        ]
        if package.isOutdated {
            trailing.append(configuredAction(
                Buttons.primary("Upgrade", target: self, action: #selector(upgrade)),
                symbol: "arrow.up.circle",
                subject: name
            ))
        }
        trailing.append(configuredAction(
            Buttons.destructive("Uninstall", target: self, action: #selector(uninstall)),
            symbol: "trash",
            subject: name
        ))

        actionBar.setLeading(leading)
        actionBar.setTrailing(trailing)
    }

    private func appIcon(for package: HomebrewPackage) -> NSImage? {
        guard package.isCask else { return nil }
        guard let app = package.actualAppURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    // MARK: - Service

    private func showService(_ service: ServiceInfo) {
        emptyState.isHidden = true
        setChromeHidden(false)
        setTabsHidden(true)
        header.setBadge(symbol: "gearshape.2")
        header.title = service.name
        // Symbol + tint, so "running" survives grayscale and Increased Contrast
        // rather than living only in a green tile.
        if service.isRunning {
            header.setStatus("Running", symbol: "play.fill", tint: .systemGreen)
        } else {
            header.setSummary("Service · \(service.status.capitalized)")
        }

        clearSections()
        var keyValues: [KeyValueView] = [KeyValueView(key: "Status", value: service.status.capitalized)]
        if let user = service.user, !user.isEmpty { keyValues.append(KeyValueView(key: "User", value: user)) }
        if let file = service.file, !file.isEmpty { keyValues.append(KeyValueView(key: "File", value: file)) }
        addSection("Information", kvGrid(keyValues))

        actionBar.setLeading([])
        if service.isRunning {
            actionBar.setTrailing([
                configuredAction(
                    Buttons.secondary("Stop", target: self, action: #selector(stopService)),
                    symbol: "stop.circle",
                    subject: service.name
                ),
                configuredAction(
                    Buttons.secondary("Restart", target: self, action: #selector(restartService)),
                    symbol: "arrow.clockwise.circle",
                    subject: service.name
                )
            ])
        } else {
            actionBar.setTrailing([
                configuredAction(
                    Buttons.primary("Start", target: self, action: #selector(startService)),
                    symbol: "play.circle",
                    subject: service.name
                )
            ])
        }
        actionBar.isHidden = false
    }

    // MARK: - Tap

    private func showTap(_ tap: TapInfo) {
        emptyState.isHidden = true
        setChromeHidden(false)
        setTabsHidden(true)
        header.setBadge(symbol: "arrow.triangle.branch")
        header.title = tap.name
        header.setSummary("Tap · \(tap.packageCount) package\(tap.packageCount == 1 ? "" : "s")")

        tapPackageRefs = tap.packageRefs.sorted {
            $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending
        }
        tapInstalledIDs = []
        tapPackagesLoaded = false
        tapPackagesError = ""
        renderTapContent(tap)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try HomebrewService.installedPackages().filter { $0.tap == tap.name } }
            DispatchQueue.main.async {
                guard let self, case .tap(let current)? = self.selection, current.name == tap.name else { return }
                switch result {
                case .success(let packages):
                    self.tapInstalledIDs = Set(packages.map { self.tapPackageID($0.reference) })
                    self.tapPackagesLoaded = true
                case .failure(let error):
                    self.tapPackagesError = error.localizedDescription
                }
                self.renderTapContent(tap)
            }
        }
    }

    private func renderTapContent(_ tap: TapInfo) {
        clearSections()
        var keyValues: [KeyValueView] = [
            KeyValueView(key: "Official", value: (tap.official ?? false) ? "Yes" : "No")
        ]
        if let remote = tap.remote, !remote.isEmpty {
            keyValues.append(KeyValueView(
                key: "Remote",
                value: shortHost(remote),
                link: remote.hasPrefix("http")
            ) { [weak self] in self?.openHomepage() })
        }
        keyValues.append(KeyValueView(key: "Formulae", value: "\(tap.formulaNames?.count ?? 0)"))
        keyValues.append(KeyValueView(key: "Casks", value: "\(tap.caskTokens?.count ?? 0)"))
        addSection("Information", kvGrid(keyValues))

        if !tapPackageRefs.isEmpty {
            tapPackagePicker.removeAllItems()
            tapPackagePicker.addItems(withTitles: tapPackageRefs.map { ref in
                let status = tapInstalledIDs.contains(tapPackageID(ref)) ? " — Installed" : ""
                return "\(ref.token)\(status)"
            })
            tapPackagePicker.target = self
            tapPackagePicker.action = #selector(tapPackageSelectionChanged)
            tapPackagePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
            updateTapPackageButton()
            let row = NSStackView(views: [tapPackagePicker, tapPackageButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Spacing.sm
            addSection("Packages", row)
            if !tapPackagesError.isEmpty {
                addSection("Couldn't inspect installed packages", warningLabel(tapPackagesError))
            }
        }

        actionBar.setLeading([])
        if tap.official ?? false {
            actionBar.setTrailing([])
            actionBar.isHidden = true
        } else {
            actionBar.setTrailing([
                configuredAction(
                    Buttons.destructive("Remove Tap", target: self, action: #selector(untap)),
                    symbol: "trash",
                    subject: tap.name
                )
            ])
            actionBar.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func zapToggled(_ sender: NSButton) { zapEnabled = sender.state == .on }

    @objc private func installPackage() {
        guard case .package(let package)? = selection else { return }
        runMutation(
            title: "Installing \(package.displayName)…",
            arguments: HomebrewActions.installArgs(package.reference)
        )
    }

    @objc private func upgrade() {
        guard case .package(let package)? = selection else { return }
        runMutation(title: "Upgrading \(package.displayName)…", plan: HomebrewActions.upgradePlan(package))
    }

    @objc private func pin() {
        guard case .package(let package)? = selection else { return }
        runQuiet(
            title: "Couldn't \(package.isPinned ? "unpin" : "pin")",
            arguments: HomebrewActions.pinArgs(package)
        )
    }

    @objc private func uninstall() {
        guard case .package(let package)? = selection else { return }
        let zap = package.isCask && zapEnabled

        if Preferences.shared.confirmBeforeDelete {
            let alert = NSAlert()
            alert.messageText = "Uninstall “\(package.displayName)”?"
            var info = package.isCask
                ? (zap ? "Removes the cask and every file it created (zap). This can't be undone here."
                       : "Removes the cask. Some related files may remain — tick “zap” to remove everything.")
                : "Removes the formula via Homebrew."
            if !dependents.isEmpty {
                info += "\n\n⚠️ Still required by: \(dependents.joined(separator: ", ")). "
                    + "Removing it may break those packages."
            }
            alert.informativeText = info
            Buttons.addDestructiveConfirmation("Uninstall", to: alert)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let name = package.displayName
        runMutation(title: "Uninstalling \(name)…", arguments: HomebrewActions.uninstallArgs(package, zap: zap)) {
            TrashHistory.recordRemoval(origin: "Homebrew: \(name)", items: [package.token], bytes: 0, at: Date())
        }
    }

    @objc private func startService() { serviceControl(.start) }
    @objc private func stopService() { serviceControl(.stop) }
    @objc private func restartService() { serviceControl(.restart) }

    @objc private func tapPackageSelectionChanged() { updateTapPackageButton() }

    private func updateTapPackageButton() {
        guard tapPackagesLoaded else {
            tapPackageButton.isEnabled = false
            tapPackageButton.title = tapPackagesError.isEmpty ? "Loading…" : "Unavailable"
            return
        }
        let row = tapPackagePicker.indexOfSelectedItem
        guard tapPackageRefs.indices.contains(row) else { tapPackageButton.isEnabled = false; return }
        tapPackageButton.isEnabled = true
        let installed = tapInstalledIDs.contains(tapPackageID(tapPackageRefs[row]))
        tapPackageButton.title = installed ? "Uninstall" : "Install"
        tapPackageButton.hasDestructiveAction = installed
        tapPackageButton.keyEquivalent = ""
        tapPackageButton.image = NSImage(
            systemSymbolName: installed ? "trash" : "arrow.down.circle",
            accessibilityDescription: tapPackageButton.title
        )
    }

    @objc private func manageTapPackage() {
        let row = tapPackagePicker.indexOfSelectedItem
        guard tapPackagesLoaded, tapPackageRefs.indices.contains(row) else { return }
        let reference = tapPackageRefs[row]
        let installed = tapInstalledIDs.contains(tapPackageID(reference))
        if installed, Preferences.shared.confirmBeforeDelete {
            let alert = NSAlert()
            alert.messageText = "Uninstall \(reference.token)?"
            alert.informativeText = reference.isCask
                ? "This removes the cask through Homebrew. Related files may remain."
                : "This removes the formula through Homebrew."
            Buttons.addDestructiveConfirmation("Uninstall", to: alert)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let verb = installed ? "Uninstalling" : "Installing"
        let arguments = installed
            ? HomebrewActions.uninstallArgs(reference, zap: false)
            : HomebrewActions.installArgs(reference)
        runMutation(title: "\(verb) \(reference.token)…", arguments: arguments)
    }

    private func serviceControl(_ action: HomebrewActions.ServiceAction) {
        guard case .service(let service)? = selection else { return }
        runQuiet(
            title: "Couldn't \(action.rawValue) service",
            arguments: HomebrewActions.serviceArgs(action, name: service.name)
        )
    }

    private func tapPackageID(_ reference: HomebrewPackageRef) -> String {
        "\(reference.kind.rawValue)-\(reference.token.split(separator: "/").last ?? Substring(reference.token))"
    }

    @objc private func untap() {
        guard case .tap(let tap)? = selection else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try HomebrewService.installedPackages().filter { $0.tap == tap.name }
            }
            DispatchQueue.main.async {
                guard let self, case .tap(let current)? = self.selection, current.name == tap.name else { return }
                switch result {
                case .failure(let error):
                    self.alert("Couldn't inspect tap", error.localizedDescription)
                case .success(let installed) where !installed.isEmpty:
                    let names = installed.map(\.displayName).joined(separator: ", ")
                    self.alert("Can't remove tap", "Uninstall these packages from \(tap.name) first:\n\n\(names)")
                case .success:
                    self.confirmUntap(tap)
                }
            }
        }
    }

    private func confirmUntap(_ tap: TapInfo) {
        let alert = NSAlert()
        alert.messageText = "Remove tap “\(tap.name)”?"
        alert.informativeText = "Removes this repository from Homebrew. No installed packages from this tap were found."
        Buttons.addDestructiveConfirmation("Remove Tap", to: alert)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runQuiet(title: "Couldn't remove tap", arguments: HomebrewActions.untapArgs(tap.name))
    }

    @objc private func openHomepage() {
        let urlString: String?
        switch selection {
        case .package(let package)?: urlString = package.homepage
        case .tap(let tap)?:         urlString = tap.remote
        default:                     urlString = nil
        }
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func runMutation(title: String, arguments: [String], onSuccess: (() -> Void)? = nil) {
        runMutation(title: title, plan: HomebrewCommandPlan(arguments: arguments), onSuccess: onSuccess)
    }

    private func runMutation(title: String, plan: HomebrewCommandPlan, onSuccess: (() -> Void)? = nil) {
        let sheet = HomebrewProgressViewController(title: title, plan: plan) { [weak self] success in
            if success { onSuccess?() }
            self?.onChanged?()
        }
        presentAsSheet(sheet)
    }

    private func runQuiet(title: String, arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = HomebrewActions.runQuiet(arguments)
            DispatchQueue.main.async {
                guard let self else { return }
                if !out.ok { self.alert(title, out.stderr.isEmpty ? out.stdout : out.stderr) }
                self.onChanged?()
            }
        }
    }

    // MARK: - Section building

    private func clearSections() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func addSection(_ title: String, _ body: NSView) {
        let heading = NSTextField(labelWithString: title)
        heading.font = Typography.semibold(.headline)
        heading.textColor = .labelColor

        let container = NSStackView(views: [heading, body])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = Spacing.sm
        container.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func wrapLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Typography.subheadline
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func warningLabel(_ text: String) -> NSTextField {
        let label = wrapLabel(text)
        label.textColor = .systemOrange
        return label
    }

    private func isInstalled(_ package: HomebrewPackage) -> Bool {
        !package.installedVersion.isEmpty
    }

    private func monoLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        configuredAction(Buttons.secondary(title, target: self, action: action), symbol: symbol)
    }

    /// - Parameter subject: what the action acts on. Without it VoiceOver announces
    ///   a bare "Uninstall, button" with no idea which package is about to go.
    private func configuredAction(_ button: NSButton, symbol: String, subject: String? = nil) -> NSButton {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.setContentHuggingPriority(.required, for: .horizontal)
        if let subject, !subject.isEmpty {
            button.setAccessibilityLabel("\(button.title) \(subject)")
        }
        return button
    }

    private func kvGrid(_ items: [KeyValueView]) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < items.count {
            let rowItems = Array(items[index ..< min(index + 2, items.count)])
            let row = NSStackView(views: rowItems)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = Spacing.md
            row.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            index += 2
        }
        return column
    }

    private func shortHost(_ urlString: String) -> String {
        guard var host = URL(string: urlString)?.host else { return urlString }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
