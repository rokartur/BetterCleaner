import AppKit

/// Row cell for a single leftover file: checkbox, icon, name + path, size, and a
/// lock badge for system-domain files (which need admin rights to remove).
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameField = RevealLinkLabel()
    private let pathField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let safetyDot = NSImageView()
    private let lockView = NSImageView()

    private weak var item: FileItem?
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        for v in [checkbox, iconView, nameField, pathField, sizeField, safetyDot, lockView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        checkbox.target = self
        checkbox.action = #selector(toggled)

        safetyDot.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        safetyDot.setContentHuggingPriority(.required, for: .horizontal)

        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = Typography.body
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.font = Typography.caption
        pathField.textColor = .secondaryLabelColor
        sizeField.font = Typography.monospacedDigit(.subheadline)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        lockView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "System file")
        lockView.contentTintColor = .secondaryLabelColor
        lockView.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.listIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.listIconSize),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs + 1),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: safetyDot.leadingAnchor, constant: -Spacing.sm),

            pathField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            pathField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: safetyDot.leadingAnchor, constant: -Spacing.sm),

            safetyDot.trailingAnchor.constraint(equalTo: lockView.leadingAnchor, constant: -Spacing.sm),
            safetyDot.centerYAnchor.constraint(equalTo: centerYAnchor),

            lockView.trailingAnchor.constraint(equalTo: sizeField.leadingAnchor, constant: -Spacing.sm),
            lockView.centerYAnchor.constraint(equalTo: centerYAnchor),

            sizeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(item: FileItem) {
        self.item = item
        checkbox.state = item.isSelected ? .on : .off
        iconView.image = IconCache.icon(forPath: item.path)
        // The name reads as a link: hover underlines it, click reveals the file
        // (selected) in Finder. The path below stays a plain caption.
        nameField.url = item.url
        nameField.stringValue = item.displayName
        pathField.stringValue = item.url.deletingLastPathComponent().path
        // "≈" signals the size is a lower bound (part of the tree was unreadable).
        sizeField.stringValue = (item.sizeIsApproximate ? "≈ " : "") + FileSize.string(item.size)
        lockView.isHidden = item.domain != .system
        applySafety(item)
    }

    /// Colour-coded confidence dot: green = safe (auto-selectable), amber =
    /// review (BetterCleaner isn't certain — never pre-selected). The tooltip
    /// explains *why*, naming the category so orphan grading reads inline.
    private func applySafety(_ item: FileItem) {
        if item.isAutoSelectable {
            safetyDot.contentTintColor = .systemGreen
            safetyDot.toolTip = item.domain == .system
                ? "Safe to remove — needs an admin password."
                : "Safe to remove — \(item.category) is recreated automatically and nothing depends on it."
        } else {
            safetyDot.contentTintColor = .systemOrange
            safetyDot.toolTip = "Review before removing — BetterCleaner isn't certain this belongs to removed software (\(item.category)). Not pre-selected."
        }
    }

    @objc private func toggled() {
        item?.isSelected = checkbox.state == .on
        onToggle?()
    }
}

/// Apply the shared aggregate safety symbol to a folder/section row's dot: a
/// green checkmark when every file in the cluster is auto-selectable ("safe"),
/// an amber triangle when at least one needs review. Mirrors `FileCell`'s
/// per-row symbols so a collapsed folder telegraphs the safety of its contents.
@MainActor
private func configureSafetyDot(_ view: NSImageView, allSafe: Bool) {
    if allSafe {
        view.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Safe to remove")
        view.contentTintColor = .systemGreen
        view.toolTip = "Safe to remove — everything here is recreated automatically."
    } else {
        view.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Review before removing")
        view.contentTintColor = .systemOrange
        view.toolTip = "Review before removing — contains items BetterCleaner isn't certain about."
    }
}

/// A collapsible cluster row: checkbox + folder icon + title + safety dot +
/// "(N items · size)". Toggling the checkbox selects/deselects every file in the
/// cluster.
final class GroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupCell")

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let safetyDot = NSImageView()
    private let detailField = NSTextField(labelWithString: "")

    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        for v in [checkbox, iconView, titleField, safetyDot, detailField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.allowsMixedState = false
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        titleField.font = Typography.medium(.body)
        titleField.lineBreakMode = .byTruncatingTail
        safetyDot.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        safetyDot.setContentHuggingPriority(.required, for: .horizontal)
        detailField.font = Typography.monospacedDigit(.subheadline)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        detailField.setContentHuggingPriority(.required, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Spacing.sm),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.badgeSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.badgeSize),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.sm),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: safetyDot.leadingAnchor, constant: -Spacing.sm),
            safetyDot.trailingAnchor.constraint(equalTo: detailField.leadingAnchor, constant: -Spacing.sm),
            safetyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title: String, detail: String, checked: Bool, allSafe: Bool) {
        titleField.stringValue = title
        detailField.stringValue = detail
        checkbox.state = checked ? .on : .off
        configureSafetyDot(safetyDot, allSafe: allSafe)
    }

    @objc private func toggled() { onToggle?(checkbox.state == .on) }
}

/// Expandable section header row: a whole-category checkbox + name + aggregate.
/// Toggling the checkbox selects/deselects the entire category at once.
final class SectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SectionCell")

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let safetyDot = NSImageView()

    /// Fired with the checkbox's new state (`true` = select the category).
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        for v in [checkbox, label, safetyDot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.allowsMixedState = false
        label.font = Typography.semibold(.subheadline)
        label.textColor = .secondaryLabelColor
        safetyDot.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        safetyDot.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: Spacing.sm),
            label.trailingAnchor.constraint(lessThanOrEqualTo: safetyDot.leadingAnchor, constant: -Spacing.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            safetyDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            safetyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `checked` = the category is fully selected; `enabled` = it has at least
    /// one auto-selectable item (off for review-only groups like Spotlight, so
    /// large user data can't be swept in with one click). `allSafe` drives the
    /// aggregate safety dot.
    func configure(title: String, detail: String, checked: Bool, enabled: Bool, allSafe: Bool) {
        label.stringValue = "\(title.uppercased())   ·   \(detail)"
        checkbox.state = checked ? .on : .off
        checkbox.isEnabled = enabled
        configureSafetyDot(safetyDot, allSafe: allSafe)
    }

    @objc private func toggled() { onToggle?(checkbox.state == .on) }
}
