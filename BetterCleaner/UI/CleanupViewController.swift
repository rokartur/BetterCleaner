import AppKit

/// The "System Junk" section: broad, app-independent reclaimable space (caches,
/// logs, saved state, developer caches, opt-in backups/system dirs). Scans lazily
/// on first appearance. Safe categories arrive pre-selected.
@MainActor
final class CleanupViewController: NSViewController {
    private let fileListVC = FileListViewController()
    private var hasScanned = false

    /// Fired after each scan with this section's reclaimable (safe / auto-selectable)
    /// bytes, so `MainSplitViewController` can drive the sidebar badge + toolbar total.
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
        if let s = NavCatalog.section(id: "junk") { fileListVC.setSectionBadge(symbol: s.icon, tint: s.tint) }
    }

    func startIfNeeded() {
        guard !hasScanned else { return }
        hasScanned = true
        rescan()
    }

    func rescan() {
        fileListVC.showLoading("Scanning for system junk…")
        let includeSystem = Preferences.shared.includeSystemFiles
        let excluded = ScanExclusions.set(from: Preferences.shared.orphanExclusionURLs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = JunkScanner.scan(includeSystem: includeSystem, excluded: excluded)
            let items = sections.flatMap { $0.items }
            let total = items.reduce(0) { $0 + $1.size }
            let reclaimable = items.filter { $0.isAutoSelectable }.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileListVC.showResults(
                    sections,
                    title: "System Junk",
                    subtitle: "\(items.count) items · \(FileSize.string(total)) found · \(FileSize.string(reclaimable)) preselected"
                )
                self.onReclaimable?(reclaimable)
            }
        }
    }
}
