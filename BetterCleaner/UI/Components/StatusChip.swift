import AppKit

/// The app's one inline status/tag chip: an optional SF Symbol next to a short
/// caption on a tinted capsule.
///
/// Replaces the three near-identical pills that had drifted apart — Delete
/// History's `PillLabel` (radius 7, 8pt inset, 15% tint), Homebrew's `StatusPill`
/// (radius 4, 5pt inset, solid fill + white text) and `TagPill` (radius 4, 5pt
/// inset, quaternary fill). One radius, one inset, one tinting rule, so a status
/// reads the same everywhere in the app.
///
/// Two appearances, chosen by `tint`:
/// - **toned** (`tint != nil`) — a *state*: "In Trash", "Running", "Official".
///   Tinted text on a faint wash of the same colour.
/// - **neutral** (`tint == nil`) — a *taxonomy* label: "Formula", "Cask", "dep".
///   Secondary text on a quaternary wash; never competes with a real state.
///
/// A state chip should always pass a `symbol`: colour alone can't carry meaning
/// through grayscale, Increased Contrast, or colour-blind vision. Taxonomy chips
/// pass none — they aren't a state, so there is nothing to encode twice.
@MainActor
final class StatusChip: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let row = NSStackView()
    /// The configured state colour (`nil` = neutral taxonomy chip). Kept so the
    /// fill can be re-resolved on an appearance change.
    private var tint: NSColor?

    /// Tuned against `Typography.caption2`: tight enough to read as an annotation
    /// beside a list row, loose enough that the glyph doesn't touch the capsule.
    private static let horizontalInset: CGFloat = 6
    private static let verticalInset: CGFloat = 2

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.isHidden = true

        // Tabular digits so a count chip ("12") keeps its width as the number
        // changes instead of nudging the row's trailing edge.
        label.font = Typography.monospacedDigit(.caption2, weight: .medium)
        label.alignment = .center
        label.setAccessibilityElement(false)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// - Parameters:
    ///   - text: the caption. Keep it to one or two words.
    ///   - symbol: SF Symbol carrying the same meaning as the tint. Always pass one
    ///     for a state chip; omit for a taxonomy label.
    ///   - tint: the state colour, or `nil` for the neutral taxonomy appearance.
    func configure(text: String, symbol: String? = nil, tint: NSColor? = nil) {
        label.stringValue = text

        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.isHidden = (iconView.image == nil)
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }

        self.tint = tint
        let foreground = tint ?? .secondaryLabelColor
        label.textColor = foreground
        iconView.contentTintColor = foreground
        needsDisplay = true

        setAccessibilityLabel(text)
    }

    /// The fill is drawn rather than assigned to a layer: `cgColor` snapshots a
    /// dynamic system colour against whatever appearance happened to be current at
    /// configure time, which left the chip carrying the wrong mode's grey. Drawing
    /// resolves it against `NSAppearance.current`, which AppKit sets correctly here
    /// — so light/dark and Increased Contrast all just work.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let fill = tint?.withAlphaComponent(0.15) ?? .quaternaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds,
                     xRadius: Metrics.chipCornerRadius,
                     yRadius: Metrics.chipCornerRadius).fill()
    }
}
