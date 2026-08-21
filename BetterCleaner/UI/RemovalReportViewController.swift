import AppKit

/// Sheet shown after a removal that did not take everything with it. Counts name
/// nothing, so this lists the paths that are still on disk and why.
///
/// The list is a text view rather than a table because it has to stay readable at
/// several hundred rows: pruning languages can leave items across every app bundle
/// on the Mac.
@MainActor
final class RemovalReportViewController: NSViewController {
    /// `activateFileViewerSelecting` opens one Finder window per distinct parent
    /// folder. Above this many, revealing would bury the screen, so the sheet
    /// offers only the clipboard.
    private static let maxRevealFolders = 5

    private let reportTitle: String
    private let summary: String
    private let outcome: Trasher.Outcome

    private var leftBehind: [URL] { outcome.failed + outcome.skipped }

    /// Present only when there is something to report; a clean removal says nothing.
    ///
    /// `noun` names what was being removed ("Languages", "Items"); the title is
    /// derived here so a run that only skipped things is never announced as a
    /// failure.
    static func present(_ outcome: Trasher.Outcome, verb: String, noun: String, from presenter: NSViewController) {
        guard let summary = outcome.incompleteMessage(verb: verb) else { return }
        let title = outcome.failed.isEmpty ? "Some \(noun) Were Left in Place" : "Some \(noun) Couldn't Be Removed"
        let report = RemovalReportViewController(title: title, summary: summary, outcome: outcome)

        // The removal runs off the main thread, so `presenter` may have been torn
        // out of the view hierarchy meanwhile (a sidebar switch does exactly that).
        // Presenting from a detached controller is a silent no-op, and this report
        // is the only place the user learns what survived. `mainWindow` is nil
        // while the app is inactive — likely here, since the user just answered an
        // admin prompt — so fall back to any window that is actually on screen.
        if presenter.view.window != nil {
            presenter.presentAsSheet(report)
        } else if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let host = window.contentViewController {
            host.presentAsSheet(report)
        } else {
            // No window on screen to hang a sheet on. An alert brings its own — but
            // it does not scroll, so it gets the summary and a taste of the list.
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = summary + "\n\n" + preview(of: outcome)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func preview(of outcome: Trasher.Outcome) -> String {
        let lines = body(for: outcome).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 20 else { return lines.joined(separator: "\n") }
        return lines.prefix(20).joined(separator: "\n") + "\n…and \(lines.count - 20) more lines."
    }

    private init(title: String, summary: String, outcome: Trasher.Outcome) {
        self.reportTitle = title
        self.summary = summary
        self.outcome = outcome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The paths grouped by what happened to them. Failures carry the outcome's
    /// reason; items left alone were never attempted, so they carry their own.
    static func body(for outcome: Trasher.Outcome) -> String {
        // The reason is already in the summary label above the list; repeating it
        // here is two copies of one string to keep in sync.
        let failureHead = "COULD NOT BE REMOVED"
        let skipHead = "LEFT IN PLACE — protected by BetterCleaner, or a link to somewhere else"
        return [section(failureHead, outcome.failed), section(skipHead, outcome.skipped)]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private static func section(_ heading: String, _ urls: [URL]) -> String? {
        urls.isEmpty ? nil : ([heading] + urls.map(display)).joined(separator: "\n")
    }

    private static func display(_ url: URL) -> String {
        "  " + (url.path as NSString).abbreviatingWithTildeInPath
    }

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: reportTitle)
        titleLabel.font = Typography.semibold(.headline)

        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.textColor = .secondaryLabelColor

        let textView = NSTextView()
        let scrollView = NSScrollView()
        LogView.configure(textView, in: scrollView, accessibilityLabel: "Items still on disk")
        textView.string = Self.body(for: outcome)

        let buttons = NSStackView(views: actionButtons())
        buttons.orientation = .horizontal
        buttons.spacing = Spacing.sm
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for label in [titleLabel, summaryLabel] { label.translatesAutoresizingMaskIntoConstraints = false }
        for child in [titleLabel, summaryLabel, scrollView, buttons] { root.addSubview(child) }

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 560),
            root.heightAnchor.constraint(equalToConstant: 380),

            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.lg),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Spacing.xs),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.md),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.lg),
        ])
        view = root
    }

    private func actionButtons() -> [NSButton] {
        var buttons = [Buttons.secondary("Copy Paths", target: self, action: #selector(copyPaths))]
        if Self.revealFitsInFinder(leftBehind) {
            buttons.append(Buttons.secondary("Show in Finder", target: self, action: #selector(showInFinder)))
        }
        buttons.append(Buttons.primary("Done", target: self, action: #selector(done)))
        return buttons
    }

    /// Finder opens a window per distinct parent folder, so a wide spread has to
    /// stay on the clipboard instead.
    static func revealFitsInFinder(_ urls: [URL]) -> Bool {
        !urls.isEmpty && Set(urls.map { $0.deletingLastPathComponent() }).count <= maxRevealFolders
    }

    @objc private func copyPaths() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(leftBehind.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(leftBehind)
    }

    @objc private func done() {
        dismiss(self)
    }
}
