import AppKit

/// A sheet that streams one or more Homebrew mutations' live log. Shows a spinner + title
/// while running, the command's output as it arrives, and a button that is **Cancel**
/// during the run (terminates `brew`) then **Done** once it finishes.
///
/// `onComplete(success)` fires exactly once when the process exits, so the presenter
/// can refresh its list regardless of when the user dismisses the sheet.
@MainActor
final class HomebrewProgressViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private lazy var actionButton = Buttons.primary("Cancel", target: self, action: #selector(primaryTapped))

    private let runner = HomebrewRunner()
    private let plans: [HomebrewCommandPlan]
    private let onComplete: ((Bool) -> Void)?
    private var running = false
    private var didStart = false
    private var nextPlanIndex = 0
    private var allSucceeded = true

    private static let logFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(title: String, plans: [HomebrewCommandPlan], onComplete: ((Bool) -> Void)? = nil) {
        self.plans = plans
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = title
    }

    convenience init(title: String, plan: HomebrewCommandPlan, onComplete: ((Bool) -> Void)? = nil) {
        self.init(title: title, plans: [plan], onComplete: onComplete)
    }

    convenience init(title: String, arguments: [String], onComplete: ((Bool) -> Void)? = nil) {
        self.init(title: title, plan: HomebrewCommandPlan(arguments: arguments), onComplete: onComplete)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = NSView()

        titleLabel.font = Typography.semibold(.headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = Self.logFont
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        let header = NSStackView(views: [spinner, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.sm
        header.translatesAutoresizingMaskIntoConstraints = false

        actionButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, scrollView, actionButton] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 560),
            root.heightAnchor.constraint(equalToConstant: 360),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Spacing.lg),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Spacing.lg),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.md),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Spacing.lg),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),

            actionButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Spacing.md),
            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Spacing.lg),
            actionButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Spacing.lg),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didStart else { return }
        didStart = true
        start()
    }

    private func start() {
        running = true
        spinner.startAnimation(nil)
        runNextPlan()
    }

    private func runNextPlan() {
        guard !runner.isCancelled else { finish(false); return }
        guard nextPlanIndex < plans.count else { finish(allSucceeded); return }

        let plan = plans[nextPlanIndex]
        nextPlanIndex += 1
        if nextPlanIndex > 1 { append("\n") }
        for step in plan.steps {
            append("$ brew " + step.arguments.joined(separator: " ") + (step.isFinalizer ? "  # finally\n" : "\n"))
        }
        runner.run(plan,
                   onLine: { [weak self] line in self?.append(line + "\n") },
                   completion: { [weak self] success in
                       guard let self else { return }
                       self.allSucceeded = self.allSucceeded && success
                       self.runNextPlan()
                   })
    }

    private func finish(_ success: Bool) {
        running = false
        spinner.stopAnimation(nil)
        let footer = success ? "\n✓ Done." : (runner.isCancelled ? "\n✗ Cancelled." : "\n✗ Failed.")
        append(footer + "\n")
        actionButton.isEnabled = true
        actionButton.title = "Done"
        onComplete?(success)
    }

    @objc private func primaryTapped() {
        if running {
            runner.cancel()
            actionButton.isEnabled = false
            actionButton.title = "Cancelling…"
        } else {
            dismiss(self)
        }
    }

    private func append(_ text: String) {
        textView.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [.font: Self.logFont, .foregroundColor: NSColor.labelColor]
        ))
        textView.scrollToEndOfDocument(nil)
    }
}
