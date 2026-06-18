import AppKit

/// The "Development" section: reclaimable developer caches (Xcode DerivedData,
/// node/pip/cargo caches, IDE caches, …) grouped by environment. Lazy-scans on
/// first appearance.
@MainActor
final class DevelopmentViewController: NSViewController {
    private let fileListVC = FileListViewController()
    private var hasScanned = false

    /// Fired after each scan with this section's reclaimable (safe-cache /
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
        fileListVC.enableSearch(placeholder: "Search caches…")
        if let s = NavCatalog.section(id: "devenv") { fileListVC.setSectionBadge(symbol: s.icon) }
    }

    func startIfNeeded() {
        guard !hasScanned else { return }
        hasScanned = true
        rescan()
    }

    func rescan() {
        fileListVC.showLoading("Scanning developer caches…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = DevEnvironmentScanner.scan()
            let total = sections.reduce(0) { $0 + $1.totalSize }
            let count = sections.reduce(0) { $0 + $1.items.count }
            let reclaimable = sections.flatMap { $0.items }.filter { $0.isAutoSelectable }.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fileListVC.showResults(
                    sections,
                    title: "Development",
                    subtitle: "\(count) caches in \(sections.count) environments · \(FileSize.string(total))"
                )
                self.onReclaimable?(reclaimable)
            }
        }
    }
}
