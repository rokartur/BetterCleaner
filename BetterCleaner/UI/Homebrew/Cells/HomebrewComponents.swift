import AppKit

/// Shared visual building blocks for the Homebrew screens, styled after TapHouse:
/// rounded icon tiles, status/tag pills, key-value info rows, and a flipped
/// container for top-anchored scroll content. Native + appearance-adaptive (no
/// hardcoded dark palette).

/// A flipped view so scroll-view content lays out from the top down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Rounded icon tile: a white SF glyph on a colored rounded rect, or a real app
/// icon with rounded corners filling the tile.
final class IconTileView: NSView {
    private let imageView = NSImageView()
    private let dimension: CGFloat
    private var insetConstraints: [NSLayoutConstraint] = []

    init(size: CGFloat = 30, corner: CGFloat = 7) {
        dimension = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        let l = imageView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let t = imageView.topAnchor.constraint(equalTo: topAnchor)
        let r = imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
        let b = imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        insetConstraints = [l, t, r, b]
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            l, t, r, b,
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setInset(_ v: CGFloat) {
        insetConstraints[0].constant = v
        insetConstraints[1].constant = v
        insetConstraints[2].constant = -v
        insetConstraints[3].constant = -v
    }

    /// White SF glyph centered on a colored tile.
    func setGlyph(_ symbol: String, color: NSColor) {
        layer?.backgroundColor = color.cgColor
        setInset(dimension * 0.26)
        imageView.contentTintColor = .white
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// Real app icon, rounded, filling the tile (no colored background).
    func setAppIcon(_ image: NSImage) {
        layer?.backgroundColor = NSColor.clear.cgColor
        setInset(0)
        imageView.contentTintColor = nil
        imageView.image = image
    }
}

/// Filled colored status pill ("Update", "Running", "Official") — white text on a
/// tinted capsule.
final class StatusPill: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.semibold(.caption2)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(text: String, color: NSColor) {
        label.stringValue = text
        layer?.backgroundColor = color.cgColor
    }
}

/// Subtle gray tag pill ("Formula", "Cask", "dep") — secondary text on a faint
/// fill, matching TapHouse's inline source tags.
final class TagPill: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.medium(.caption2)
        label.textColor = .secondaryLabelColor
        label.stringValue = text
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// A stacked key/value cell: a small gray caption over its value (TapHouse's
/// "Information" grid style). The value can be a plain string or a clickable link.
final class KeyValueView: NSView {
    private var onClick: (() -> Void)?

    init(key: String, value: String, link: Bool = false, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = Typography.caption
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail

        let valueView: NSView
        if link {
            let button = NSButton(title: value, target: self, action: #selector(linkTapped))
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .linkColor
            button.alignment = .left
            button.font = Typography.subheadline
            button.setButtonType(.momentaryChange)
            valueView = button
        } else {
            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = Typography.subheadline
            valueLabel.textColor = .labelColor
            valueLabel.isSelectable = true
            valueView = valueLabel
        }
        valueView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [keyLabel, valueView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func linkTapped() { onClick?() }
}
