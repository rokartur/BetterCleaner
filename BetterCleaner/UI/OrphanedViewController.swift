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
        let exclusions = Preferences.shared.orphanExclusionURLs
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
}
