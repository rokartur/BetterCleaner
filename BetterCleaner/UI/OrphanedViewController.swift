import AppKit

/// The "Orphaned Files" section: leftover files whose owning app is no longer
/// installed. Scans lazily on first appearance.
@MainActor
final class OrphanedViewController: NSViewController {
    private let fileListVC = FileListViewController()
    private var hasScanned = false
    private var scanGeneration = 0

    /// Fired after each scan with this section's reclaimable (high-confidence /
    /// auto-selectable) bytes — drives the sidebar badge + toolbar total.
    var onReclaimable: ((Int64) -> Void)?

    override func loadView() {
        let root = NSView()
        addChild(fileListVC)
        fileListVC.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fileListVC.view)
        NSLayoutConstraint.activate([
            fileListVC.view.topAnchor.constraint(equalTo: root.topAnchor),
            fileListVC.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileListVC.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileListVC.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fileListVC.onRescanRequested = { [weak self] in self?.rescan() }
        fileListVC.onReclaimableChanged = { [weak self] bytes in self?.onReclaimable?(bytes) }
        fileListVC.enableAssignToApp { [weak self] url in self?.presentAssignSheet(for: url) }
        if let s = NavCatalog.section(id: "orphaned") { fileListVC.setSectionBadge(symbol: s.icon, tint: s.tint) }
    }

    func startIfNeeded() {
        guard !hasScanned else { return }
        hasScanned = true
        rescan()
    }

    func rescan() {
        fileListVC.showLoading("Scanning for orphaned files…", determinate: true)
        // Guard against overlapping rescans (startIfNeeded + toolbar refresh +
        // post-trash) — drop a slower older scan so it can't clobber newer results.
        scanGeneration += 1
        let generation = scanGeneration
        // Assigned files (now owned by an app) drop out of the orphan list, same as
        // user exclusions.
        let exclusions = Preferences.shared.orphanExclusionURLs + Preferences.shared.assignedURLs
        let includeSystem = Preferences.shared.includeSystemFiles
        let extra = Preferences.shared.extraScanURLs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppFinder.installedApps(extraRoots: extra)
            let index = InstalledAppsIndex(apps: apps)
            let items = OrphanScanner.scan(index: index, exclusions: exclusions, includeSystem: includeSystem) { fraction in
                DispatchQueue.main.async {
                    guard let self, generation == self.scanGeneration else { return }
                    self.fileListVC.updateProgress(fraction)
                }
            }
            let sections = LeftoverScanner.sections(from: items)
            let total = items.reduce(0) { $0 + $1.size }
            let reclaimable = items.filter { $0.isAutoSelectable }.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.fileListVC.showResults(sections, title: "Orphaned Files", subtitle: "\(items.count) items · \(FileSize.string(total))")
                self.onReclaimable?(reclaimable)
            }
        }
    }

    /// Attribute an orphaned file to an installed app. Persists it as an enabled
    /// `include` rule pinned to the chosen app's bundle id (so the per-app scan and
    /// uninstall pick it up) and drops it from the orphan list on the next scan.
    /// Reversible from Settings → Rules.
    private func presentAssignSheet(for url: URL) {
        let apps = AppFinder.installedApps(extraRoots: Preferences.shared.extraScanURLs)
            .filter { ($0.bundleID?.isEmpty == false) }
        guard !apps.isEmpty else { NSSound.beep(); return }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        popup.addItems(withTitles: apps.map { $0.name })

        let alert = NSAlert()
        alert.messageText = "Assign to App"
        alert.informativeText = "Attribute “\(url.lastPathComponent)” to an installed app. It will no longer be listed as orphaned and will be removed when you uninstall that app. You can undo this in Settings → Rules."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let app = apps[popup.indexOfSelectedItem]
        guard let bundleID = app.bundleID?.lowercased() else { return }
        let path = url.standardizedFileURL.path

        var conditions = Preferences.shared.userConditions
        let exists = conditions.contains {
            $0.kind == .include && $0.target == .path && $0.op == .equals
                && $0.value == path && $0.appScope == bundleID
        }
        if !exists {
            conditions.append(UserCondition(kind: .include, target: .path, op: .equals,
                                            value: path, appScope: bundleID))
            Preferences.shared.userConditions = conditions
        }
        rescan()
    }
}
