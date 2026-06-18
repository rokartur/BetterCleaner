import AppKit

/// Detail pane for the Homebrew page. Renders whichever item the master list
/// selected — a package, a service, or a tap — with its metadata and the actions
/// that apply to it:
///
/// - **Package**: Homepage, Upgrade (when outdated), Uninstall (casks offer a *zap*
///   checkbox to remove every related file). Formulae also show their dependency
///   tree and warn when something still depends on them.
/// - **Service**: Start / Stop / Restart.
/// - **Tap**: Homepage (remote), Remove Tap.
///
/// Package mutations run in a streaming `HomebrewProgressViewController` sheet; quick
/// service/tap commands run inline. `onChanged` fires after any mutation so the list
/// refreshes.
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

    private let header = PageHeaderView(titleTruncation: .byTruncatingMiddle)
    private let infoTextView = NSTextView()
    private let infoScroll = NSScrollView()
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

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: - Layout

    override func loadView() {
        header.setBadge(symbol: "cup.and.saucer.fill")
        header.translatesAutoresizingMaskIntoConstraints = false

        infoTextView.isEditable = false
        infoTextView.isSelectable = true
        infoTextView.drawsBackground = false
        infoTextView.textContainerInset = NSSize(width: 0, height: 4)
        infoTextView.isVerticallyResizable = true
        infoTextView.isHorizontallyResizable = false
        infoTextView.textContainer?.widthTracksTextView = true
        infoTextView.autoresizingMask = [.width]
        infoTextView.minSize = NSSize(width: 0, height: 0)
        infoTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        infoScroll.translatesAutoresizingMaskIntoConstraints = false
        infoScroll.hasVerticalScroller = true
        infoScroll.drawsBackground = false
        infoScroll.documentView = infoTextView

        statusLabel.font = Typography.subheadline
        statusLabel.textColor = .secondaryLabelColor

        let footer = ActionBarView(
            leading: [statusLabel, zapCheckbox],
            trailing: [homepageButton, startButton, stopButton, restartButton, upgradeButton, untapButton, uninstallButton]
        )
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for v in [header, infoScroll, footer, emptyState, loadingView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            infoScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            infoScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            infoScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            footer.topAnchor.constraint(equalTo: infoScroll.bottomAnchor, constant: Spacing.sm),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.md),

            emptyState.leadingAnchor.constraint(equalTo: infoScroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: infoScroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: infoScroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: infoScroll.bottomAnchor),

            loadingView.leadingAnchor.constraint(equalTo: infoScroll.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: infoScroll.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: infoScroll.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: infoScroll.bottomAnchor),
        ])
        view = root
        showPlaceholder()
    }

    // MARK: - Public entry

    func show(_ selection: HomebrewSelection?) {
        dependents = []
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
        header.title = "Homebrew"
        header.summary = ""
        header.detail = ""
        setInfo("")
        emptyState.configure(symbol: "cup.and.saucer",
                             title: "Select an item",
                             message: "Choose a package, service, or tap to manage it.")
        emptyState.isHidden = false
    }

    // MARK: - Package

    private func showPackage(_ p: HomebrewPackage) {
        emptyState.isHidden = true
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

        var text = p.description.isEmpty ? "" : p.description + "\n\n"
        text += line("Kind", p.isCask ? "Cask" : "Formula")
        text += line("Installed", p.installedVersion)
        if !p.latestVersion.isEmpty, p.latestVersion != p.installedVersion {
            text += line("Latest", p.latestVersion + (p.isOutdated ? "  (update available)" : ""))
        }
        if !p.tap.isEmpty { text += line("Tap", p.tap) }
        if !p.isCask { text += line("Installed on request", p.installedOnRequest ? "Yes" : "No (as a dependency)") }
        if !p.dependencies.isEmpty { text += line("Dependencies", p.dependencies.joined(separator: ", ")) }
        setInfo(text)

        // Formulae: load the dependency tree + reverse dependents off the main thread.
        guard !p.isCask else { return }
        let token = p.token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = HomebrewService.dependencyTree(token: token)
            let usedBy = HomebrewService.usedBy(token: token)
            DispatchQueue.main.async {
                guard let self, case .package(let current) = self.selection, current.token == token else { return }
                self.dependents = usedBy
                var extra = ""
                if !usedBy.isEmpty { extra += "\n" + self.line("Required by", usedBy.joined(separator: ", ")) }
                if !tree.isEmpty { extra += "\nDependency tree:\n" + tree }
                if !extra.isEmpty { self.appendInfo(extra) }
            }
        }
    }

    private func packageSummary(_ p: HomebrewPackage) -> String {
        var parts: [String] = [p.isCask ? "Cask" : "Formula"]
        if !p.installedVersion.isEmpty { parts.append("v\(p.installedVersion)") }
        if p.isPinned { parts.append("pinned") }
        if p.isOutdated { parts.append("update available") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Service

    private func showService(_ s: ServiceInfo) {
        emptyState.isHidden = true
        zapCheckbox.isHidden = true
        header.title = s.name
        header.summary = "Service  ·  \(s.status.capitalized)"
        header.detail = s.file ?? ""
        statusLabel.stringValue = ""
        setButtons(visible: s.isRunning ? [stopButton, restartButton] : [startButton])

        var text = line("Status", s.status.capitalized)
        if let user = s.user, !user.isEmpty { text += line("User", user) }
        if let file = s.file, !file.isEmpty { text += line("File", file) }
        setInfo(text)
    }

    // MARK: - Tap

    private func showTap(_ t: TapInfo) {
        emptyState.isHidden = true
        zapCheckbox.isHidden = true
        header.title = t.name
        header.summary = "Tap  ·  \(t.packageCount) package\(t.packageCount == 1 ? "" : "s")"
        header.detail = t.remote ?? ""
        statusLabel.stringValue = ""
        var buttons: [NSButton] = []
        if (t.remote ?? "").hasPrefix("http") { buttons.append(homepageButton) }
        // Official core taps can't be removed; only offer Remove for third-party taps.
        if !(t.official ?? false) { buttons.append(untapButton) }
        setButtons(visible: buttons)

        var text = line("Tap", t.name)
        if let remote = t.remote, !remote.isEmpty { text += line("Remote", remote) }
        text += line("Official", (t.official ?? false) ? "Yes" : "No")
        let formulae = t.formulaNames ?? []
        let casks = t.caskTokens ?? []
        if !formulae.isEmpty { text += "\nFormulae:\n" + formulae.joined(separator: ", ") + "\n" }
        if !casks.isEmpty { text += "\nCasks:\n" + casks.joined(separator: ", ") + "\n" }
        setInfo(text)
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

    // MARK: - Info text helpers

    private func line(_ key: String, _ value: String) -> String {
        value.isEmpty ? "" : "\(key): \(value)\n"
    }

    private func setInfo(_ text: String) {
        infoTextView.textStorage?.setAttributedString(attributed(text))
    }

    private func appendInfo(_ text: String) {
        infoTextView.textStorage?.append(attributed(text))
    }

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Self.monoFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
