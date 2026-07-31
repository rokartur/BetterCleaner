import AppKit

/// Hosts the detail area and swaps a single child view controller for the
/// currently selected navigation section.
@MainActor
final class ContainerViewController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func setContent(_ vc: NSViewController) {
        guard current !== vc else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()

        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = vc
    }
}
