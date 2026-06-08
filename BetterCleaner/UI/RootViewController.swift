import AppKit

/// The window's content controller: hosts the main split plus a full-window
/// drag-drop overlay. Registers for `.app` file drops on its own (always-present)
/// view so dragging an app anywhere over the window scans it — a hidden overlay
/// can't receive drag messages, so this container owns the dragging and merely
/// toggles the overlay's visibility.
@MainActor
final class RootViewController: NSViewController {
    private let split: MainSplitViewController
    private let overlay = DropZoneOverlayView()

    init(split: MainSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = DropTargetView()
        root.onHoverChange = { [weak self] hovering in self?.overlay.isHidden = !hovering }
        root.onDrop = { [weak self] url in
            guard let self, let app = AppFinder.app(at: url) else { return false }
            // Route through selectApp so it switches to the Applications page,
            // uncollapses the sidebar, and scans — same as picking it in the list.
            self.split.selectApp(name: app.name, path: url.path)
            return true
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        view.addSubview(overlay) // on top of the split

        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        view.registerForDraggedTypes([.fileURL])
    }
}

/// Plain container that accepts `.app` file drags anywhere over the window and
/// reports them. It is the only view registered for `.fileURL`, so AppKit routes
/// drags up to this ancestor from the (unregistered) content views above it.
private final class DropTargetView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onDrop: ((URL) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard appURL(from: sender) != nil else { return [] }
        onHoverChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        appURL(from: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHoverChange?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHoverChange?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        appURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onHoverChange?(false) }
        guard let url = appURL(from: sender) else { return false }
        return onDrop?(url) ?? false
    }

    private func appURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return nil }
        return urls.first { $0.pathExtension == "app" }
    }
}
