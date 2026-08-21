import AppKit

/// Full-page Homebrew health and maintenance dashboard. Read-only data loads in
/// the background; update and cleanup use the existing streaming progress sheet.
@MainActor
final class HomebrewMaintenanceViewController: NSViewController {
    var onChanged: (() -> Void)?

    private let header = PageHeaderView()
    private let activity = NSProgressIndicator()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private let currentVersionLabel = NSTextField(labelWithString: "—")
    private let latestVersionLabel = NSTextField(labelWithString: "—")
    private let versionStatusLabel = NSTextField(labelWithString: "Not checked")

    private let doctorStatusLabel = NSTextField(labelWithString: "Not checked")
    private let doctorTextView = NSTextView()
    private let doctorScrollView = NSScrollView()

    private let cacheSizeLabel = NSTextField(labelWithString: "—")
    private let analyticsStatusLabel = NSTextField(labelWithString: "Not checked")
    private let analyticsSwitch = NSSwitch()

    private let installedCountLabel = NSTextField(labelWithString: "—")
    private let outdatedCountLabel = NSTextField(labelWithString: "—")
    private let servicesCountLabel = NSTextField(labelWithString: "—")
    private let tapsCountLabel = NSTextField(labelWithString: "—")

    private lazy var reloadButton = Buttons.secondary("Reload", target: self, action: #selector(reloadTapped))
    private lazy var updateButton = Buttons.primary("Update Homebrew", target: self, action: #selector(updateHomebrew))
    private lazy var doctorButton = Buttons.secondary("Run Doctor", target: self, action: #selector(runDoctor))
    private lazy var clearCacheButton = Buttons.secondary("Clear Cache…", target: self, action: #selector(clearCache))

    private var snapshot: HomebrewMaintenanceSnapshot?
    private var didLoadSnapshot = false
    private var loadGeneration = 0
    private var isBusy = false

    override func loadView() {
        // The toolbar title says "Maintenance"; the header keeps only the one-line
        // description of what lives on this page.
        header.summary = "Health, cache, analytics, and installation statistics"
        header.translatesAutoresizingMaskIntoConstraints = false

        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        activity.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = Typography.footnote
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = true
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        configureValueLabel(currentVersionLabel)
        configureValueLabel(latestVersionLabel)
        configureValueLabel(versionStatusLabel)
        configureValueLabel(cacheSizeLabel, large: true)
        configureValueLabel(analyticsStatusLabel)
        [installedCountLabel, outdatedCountLabel, servicesCountLabel, tapsCountLabel].forEach {
            configureValueLabel($0, large: true)
            $0.alignment = .center
        }

        LogView.configure(doctorTextView, in: doctorScrollView, accessibilityLabel: "Doctor output")
        analyticsSwitch.target = self
        analyticsSwitch.action = #selector(analyticsChanged)
        analyticsSwitch.toolTip = "Enable or disable Homebrew's anonymous analytics preference."

        reloadButton.toolTip = "Reload Homebrew health and statistics."
        updateButton.toolTip = "Run brew update and show its complete live log."
        doctorButton.toolTip = "Run brew doctor again."
        clearCacheButton.toolTip = "Remove cached Homebrew downloads and stale files."

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [header, headerSpacer, activity, reloadButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Spacing.sm

        let versionMetrics = metricRow([
            metric(title: "Current", value: currentVersionLabel),
            metric(title: "Latest stable", value: latestVersionLabel),
            metric(title: "Status", value: versionStatusLabel),
        ])
        let versionSection = section(
            title: "Homebrew",
            subtitle: "The installed brew version compared with the latest stable GitHub release.",
            actions: [updateButton],
            body: versionMetrics
        )

        doctorStatusLabel.font = Typography.medium(.subheadline)
        let doctorBody = NSStackView(views: [doctorStatusLabel, doctorScrollView])
        doctorBody.orientation = .vertical
        doctorBody.alignment = .leading
        doctorBody.spacing = Spacing.sm
        doctorScrollView.widthAnchor.constraint(equalTo: doctorBody.widthAnchor).isActive = true
        doctorScrollView.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let doctorSection = section(
            title: "Doctor",
            subtitle: "Homebrew's diagnostic result, complete output, and process exit status.",
            actions: [doctorButton],
            body: doctorBody
        )

        let cacheBody = metricRow([
            metric(title: "Cache on disk", value: cacheSizeLabel),
            flexibleSpace(),
        ])
        let cacheSection = section(
            title: "Cache",
            subtitle: "Downloaded bottles, casks, and other files in Homebrew's cache directory.",
            actions: [clearCacheButton],
            body: cacheBody
        )

        let analyticsText = NSStackView(views: [
            analyticsStatusLabel,
            secondaryLabel("This changes Homebrew's own analytics preference; BetterCleaner does not collect analytics."),
        ])
        analyticsText.orientation = .vertical
        analyticsText.alignment = .leading
        analyticsText.spacing = Spacing.xs
        let analyticsSpacer = flexibleSpace()
        let analyticsBody = NSStackView(views: [analyticsText, analyticsSpacer, analyticsSwitch])
        analyticsBody.orientation = .horizontal
        analyticsBody.alignment = .centerY
        analyticsBody.spacing = Spacing.md
        let analyticsSection = section(
            title: "Analytics",
            subtitle: "Inspect or change the preference managed by brew analytics.",
            body: analyticsBody
        )

        let statsBody = metricRow([
            metric(title: "Installed", value: installedCountLabel, centered: true),
            metric(title: "Outdated", value: outdatedCountLabel, centered: true),
            metric(title: "Services", value: servicesCountLabel, centered: true),
            metric(title: "Taps", value: tapsCountLabel, centered: true),
        ])
        let statsSection = section(
            title: "Statistics",
            subtitle: "A current summary of packages and Homebrew integrations.",
            body: statsBody
        )

        let contentStack = NSStackView(views: [
            headerRow,
            errorLabel,
            versionSection,
            doctorSection,
            cacheSection,
            analyticsSection,
            statsSection,
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Spacing.xl
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        for item in [headerRow, errorLabel, versionSection, doctorSection,
                     cacheSection, analyticsSection, statsSection] {
            item.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document

        let root = NSView()
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: Spacing.lg),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Spacing.xl),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Spacing.xl),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Spacing.xl),
        ])
        view = root
        renderPlaceholder()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    func startIfNeeded() {
        guard !didLoadSnapshot else { return }
        didLoadSnapshot = true
        reload()
    }

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        setBusy(true)
        renderErrors([])

        Task { [weak self] in
            let loaded = await HomebrewMaintenance.loadSnapshot()
            guard let self, generation == self.loadGeneration else { return }
            self.snapshot = loaded
            self.render(loaded)
            self.setBusy(false)
        }
    }

    // MARK: - Actions

    @objc private func reloadTapped() {
        didLoadSnapshot = true
        reload()
    }

    @objc private func updateHomebrew() {
        guard snapshot?.isInstalled == true else { return }
        presentProgress(
            title: "Updating Homebrew…",
            arguments: HomebrewActions.updateArgs(),
            notifyChanged: true
        )
    }

    @objc private func runDoctor() {
        let previousReport = snapshot?.doctor
        setBusy(true)
        doctorStatusLabel.stringValue = "Running brew doctor…"
        doctorStatusLabel.textColor = .secondaryLabelColor
        doctorTextView.string = ""

        Task { [weak self] in
            do {
                let report = try await HomebrewMaintenance.runDoctor()
                guard let self else { return }
                self.snapshot?.doctor = report
                self.snapshot?.errors.removeAll { $0.hasPrefix("Doctor:") }
                self.renderDoctor(report)
                self.renderErrors(self.snapshot?.errors ?? [])
                self.setBusy(false)
            } catch {
                guard let self else { return }
                if let previousReport {
                    self.renderDoctor(previousReport)
                } else {
                    self.doctorStatusLabel.stringValue = "Unavailable"
                    self.doctorStatusLabel.textColor = .secondaryLabelColor
                    self.doctorTextView.string = "No doctor report was returned."
                }
                self.renderErrors((self.snapshot?.errors ?? []) + ["Doctor: \(error.localizedDescription)"])
                self.setBusy(false)
            }
        }
    }

    @objc private func clearCache() {
        let alert = NSAlert()
        alert.messageText = "Clear the Homebrew cache?"
        alert.informativeText = "Homebrew will remove cached downloads and stale files it considers safe to clean. Packages can download these files again when needed."
        Buttons.addDestructiveConfirmation("Clear Cache", to: alert)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presentProgress(
            title: "Clearing Homebrew cache…",
            arguments: HomebrewActions.cleanupArgs(),
            notifyChanged: false
        )
    }

    @objc private func analyticsChanged() {
        let previous = snapshot?.analyticsEnabled ?? false
        let requested = analyticsSwitch.state == .on
        setBusy(true)
        analyticsSwitch.state = requested ? .on : .off
        analyticsStatusLabel.stringValue = requested ? "Enabling…" : "Disabling…"
        analyticsStatusLabel.textColor = .secondaryLabelColor

        Task { [weak self] in
            do {
                let actual = try await HomebrewMaintenance.setAnalytics(enabled: requested)
                guard let self else { return }
                self.snapshot?.analyticsEnabled = actual
                self.snapshot?.errors.removeAll { $0.hasPrefix("Analytics:") }
                self.renderAnalytics(actual)
                var errors = self.snapshot?.errors ?? []
                if actual != requested {
                    errors.append("Analytics: Homebrew did not retain the requested setting.")
                }
                self.renderErrors(errors)
                self.setBusy(false)
            } catch {
                guard let self else { return }
                self.analyticsSwitch.state = previous ? .on : .off
                self.renderAnalytics(previous)
                self.renderErrors((self.snapshot?.errors ?? []) + ["Analytics: \(error.localizedDescription)"])
                self.setBusy(false)
            }
        }
    }

    private func presentProgress(title: String, arguments: [String], notifyChanged: Bool) {
        let progress = HomebrewProgressViewController(title: title, arguments: arguments) { [weak self] success in
            guard let self else { return }
            if success, notifyChanged { self.onChanged?() }
            self.reload()
        }
        presentAsSheet(progress)
    }

    // MARK: - Rendering

    private func renderPlaceholder() {
        currentVersionLabel.stringValue = "—"
        latestVersionLabel.stringValue = "—"
        versionStatusLabel.stringValue = "Not checked"
        doctorStatusLabel.stringValue = "Not checked"
        doctorStatusLabel.textColor = .secondaryLabelColor
        doctorTextView.string = "Run or reload to see brew doctor's complete output."
        cacheSizeLabel.stringValue = "—"
        analyticsStatusLabel.stringValue = "Not checked"
        analyticsSwitch.state = .off
        [installedCountLabel, outdatedCountLabel, servicesCountLabel, tapsCountLabel].forEach {
            $0.stringValue = "—"
        }
        updateControlStates()
    }

    private func render(_ snapshot: HomebrewMaintenanceSnapshot) {
        currentVersionLabel.stringValue = snapshot.currentVersion.map { "v\($0)" } ?? "Unavailable"
        latestVersionLabel.stringValue = snapshot.latestVersion.map { "v\($0)" } ?? "Unavailable"

        if snapshot.isUpdateAvailable {
            versionStatusLabel.stringValue = "Update available"
            versionStatusLabel.textColor = .systemOrange
        } else if snapshot.currentVersion != nil, snapshot.latestVersion != nil {
            versionStatusLabel.stringValue = "Up to date"
            versionStatusLabel.textColor = .systemGreen
        } else {
            versionStatusLabel.stringValue = "Couldn't compare"
            versionStatusLabel.textColor = .secondaryLabelColor
        }

        if let doctor = snapshot.doctor {
            renderDoctor(doctor)
        } else {
            doctorStatusLabel.stringValue = "Unavailable"
            doctorStatusLabel.textColor = .secondaryLabelColor
            doctorTextView.string = "No doctor report was returned."
        }

        cacheSizeLabel.stringValue = snapshot.cacheBytes.map(FileSize.string) ?? "Unavailable"
        if let analytics = snapshot.analyticsEnabled {
            renderAnalytics(analytics)
        } else {
            analyticsStatusLabel.stringValue = "Unavailable"
            analyticsStatusLabel.textColor = .secondaryLabelColor
            analyticsSwitch.state = .off
        }

        installedCountLabel.stringValue = countString(snapshot.stats.installed)
        outdatedCountLabel.stringValue = countString(snapshot.stats.outdated)
        servicesCountLabel.stringValue = countString(snapshot.stats.services)
        tapsCountLabel.stringValue = countString(snapshot.stats.taps)
        renderErrors(snapshot.errors)
    }

    private func renderDoctor(_ report: HomebrewDoctorReport) {
        if report.isHealthy {
            doctorStatusLabel.stringValue = "Ready · exit status 0"
            doctorStatusLabel.textColor = .systemGreen
        } else {
            doctorStatusLabel.stringValue = "Issues found · exit status \(report.exitStatus)"
            doctorStatusLabel.textColor = .systemOrange
        }
        doctorTextView.string = report.output.isEmpty ? "(brew doctor produced no output.)" : report.output
    }

    private func renderAnalytics(_ enabled: Bool) {
        analyticsSwitch.state = enabled ? .on : .off
        analyticsStatusLabel.stringValue = enabled ? "Analytics enabled" : "Analytics disabled"
        analyticsStatusLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
    }

    private func renderErrors(_ errors: [String]) {
        errorLabel.stringValue = errors.map { "• \($0)" }.joined(separator: "\n")
        errorLabel.isHidden = errors.isEmpty
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
        updateControlStates()
    }

    private func updateControlStates() {
        let installed = snapshot?.isInstalled == true
        reloadButton.isEnabled = !isBusy
        updateButton.isEnabled = !isBusy && installed
        doctorButton.isEnabled = !isBusy && installed
        clearCacheButton.isEnabled = !isBusy && installed
        analyticsSwitch.isEnabled = !isBusy && snapshot?.analyticsEnabled != nil
    }

    private func countString(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    // MARK: - View construction

    private func configureValueLabel(_ label: NSTextField, large: Bool = false) {
        label.font = large
            ? Typography.monospacedDigit(.title3, weight: .semibold)
            : Typography.medium(.subheadline)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = true
    }

    private func section(title: String, subtitle: String, actions: [NSView] = [], body: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.semibold(.headline)

        let subtitleLabel = secondaryLabel(subtitle)
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Spacing.xs
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = flexibleSpace()
        let headerRow = NSStackView(views: [text, spacer] + actions)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Spacing.sm

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerRow, body, separator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.md
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func metric(title: String, value: NSTextField, centered: Bool = false) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.caption
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.alignment = centered ? .center : .left
        value.alignment = centered ? .center : .left

        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.alignment = centered ? .centerX : .leading
        stack.spacing = Spacing.xs
        return stack
    }

    private func metricRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Spacing.xl
        row.distribution = .fillEqually
        return row
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Typography.footnote
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
}
