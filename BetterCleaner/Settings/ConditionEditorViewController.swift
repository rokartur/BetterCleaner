import AppKit

/// Modal sheet to create or edit one `UserCondition`. Live-validates a regex
/// pattern and disables Save while it's invalid. Calls `onSave` with the result.
@MainActor
final class ConditionEditorViewController: NSViewController, NSTextFieldDelegate {
    var onSave: ((UserCondition) -> Void)?

    private var condition: UserCondition
    private let apps: [InstalledApp]

    private let kindPopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let opPopup = NSPopUpButton()
    private let scopePopup = NSPopUpButton()
    private let valueField = NSTextField()
    private let validationLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// `apps` populates the per-app scope picker. `existing` edits a rule in place.
    init(existing: UserCondition? = nil, apps: [InstalledApp]) {
        self.condition = existing ?? UserCondition()
        self.apps = apps
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let titleLabel = NSTextField(labelWithString: "Matching Rule")
        titleLabel.font = Typography.semibold(.title3)

        kindPopup.addItems(withTitles: UserCondition.Kind.allCases.map { $0.title })
        kindPopup.selectItem(at: UserCondition.Kind.allCases.firstIndex(of: condition.kind) ?? 0)

        targetPopup.addItems(withTitles: UserCondition.Target.allCases.map { $0.title })
        targetPopup.selectItem(at: UserCondition.Target.allCases.firstIndex(of: condition.target) ?? 0)

        opPopup.addItems(withTitles: UserCondition.Op.allCases.map { $0.title })
        opPopup.selectItem(at: UserCondition.Op.allCases.firstIndex(of: condition.op) ?? 0)
        opPopup.target = self
        opPopup.action = #selector(opChanged)

        scopePopup.addItem(withTitle: "All apps")
        for app in apps {
            let label = app.bundleID.map { "\(app.name) (\($0))" } ?? app.name
            scopePopup.addItem(withTitle: label)
        }
        // Select the matching app row if the rule is pinned, else "All apps".
        if let scope = condition.appScope,
           let idx = apps.firstIndex(where: { $0.bundleID?.lowercased() == scope }) {
            scopePopup.selectItem(at: idx + 1)
        } else {
            scopePopup.selectItem(at: 0)
        }

        valueField.stringValue = condition.value
        valueField.placeholderString = "value"
        valueField.delegate = self

        validationLabel.font = Typography.caption
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        kindPopup.setAccessibilityLabel("Action")
        targetPopup.setAccessibilityLabel("Match")
        opPopup.setAccessibilityLabel("Condition")
        valueField.setAccessibilityLabel("Value")
        scopePopup.setAccessibilityLabel("Apply to")

        let grid = NSGridView(views: [
            [label("Action"), kindPopup],
            [label("Match"), targetPopup],
            [label("Condition"), opPopup],
            [label("Value"), valueField],
            [label("Apply to"), scopePopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [titleLabel, grid, validationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        validate()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Typography.body
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Actions

    @objc private func opChanged() { validate() }

    func controlTextDidChange(_ obj: Notification) { validate() }

    /// Disable Save when a regex pattern won't compile, or the value is empty.
    private func validate() {
        let value = valueField.stringValue
        let isRegex = UserCondition.Op.allCases[max(opPopup.indexOfSelectedItem, 0)] == .regex
        if value.isEmpty {
            saveButton.isEnabled = false
            validationLabel.isHidden = true
        } else if isRegex, !SafeRegex.isValid(value) {
            saveButton.isEnabled = false
            validationLabel.stringValue = "Invalid regular expression."
            validationLabel.isHidden = false
        } else {
            saveButton.isEnabled = true
            validationLabel.isHidden = true
        }
    }

    @objc private func save() {
        condition.kind = UserCondition.Kind.allCases[max(kindPopup.indexOfSelectedItem, 0)]
        condition.target = UserCondition.Target.allCases[max(targetPopup.indexOfSelectedItem, 0)]
        condition.op = UserCondition.Op.allCases[max(opPopup.indexOfSelectedItem, 0)]
        condition.value = valueField.stringValue
        let scopeIndex = scopePopup.indexOfSelectedItem
        condition.appScope = scopeIndex <= 0 ? nil : apps[scopeIndex - 1].bundleID?.lowercased()
        onSave?(condition)
        dismiss(self)
    }

    @objc private func cancel() { dismiss(self) }
}
