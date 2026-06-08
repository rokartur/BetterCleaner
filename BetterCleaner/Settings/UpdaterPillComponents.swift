import AppKit
import QuartzCore

// Self-contained settings UI helpers for the updater status surface in the
// About tab. Mirrors the capsule used across the Better* app family but carries
// no Liquid Glass dependency — plain layer-backed chrome only.

// MARK: - Section chrome (shared colors)

enum AppKitSectionChrome {
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 0.5

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func fillColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.035)
                           : NSColor.black.withAlphaComponent(0.025)
    }

    static func borderColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.06)
                           : NSColor.black.withAlphaComponent(0.05)
    }
}

// MARK: - Capsule action pill

/// Pill-shaped control with an optional SF Symbol + label. `.subtle` blends into
/// the section chrome; `.prominent` tints with an accent color. Animates hover /
/// press and runs `action` on click.
@MainActor
final class CapsulePillView: NSView {

    enum Style {
        case subtle
        case prominent(NSColor)
    }

    private enum Animation {
        static let hoverDuration: TimeInterval = 0.12
        static let pressInDuration: TimeInterval = 0.08
        static let pressOutDuration: TimeInterval = 0.16
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var topConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var style: Style = .subtle
    private var action: (() -> Void)?
    private var baseHorizontalPadding: CGFloat = 12
    private var baseVerticalPadding: CGFloat = 5

    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            if !isHovering { isPressing = false }
            updateAppearance(animated: true, duration: Animation.hoverDuration)
        }
    }
    private var isPressing = false {
        didSet {
            guard oldValue != isPressing else { return }
            updateAppearance(
                animated: true,
                duration: isPressing ? Animation.pressInDuration : Animation.pressOutDuration
            )
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        topConstraint = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: baseVerticalPadding)
        leadingConstraint = contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: baseHorizontalPadding)
        trailingConstraint = contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -baseHorizontalPadding)
        bottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -baseVerticalPadding)
        NSLayoutConstraint.activate([
            topConstraint!,
            leadingConstraint!,
            trailingConstraint!,
            bottomConstraint!,
        ])

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(label)

        updateAppearance(animated: false)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard action != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard action != nil else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard action != nil else { return }
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard action != nil else { return }
        isPressing = true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard action != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        isPressing = bounds.contains(location)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let action else { return }
        let location = convert(event.locationInWindow, from: nil)
        isPressing = false
        if bounds.contains(location) {
            action()
        }
    }

    func configure(
        text: String,
        iconName: String? = nil,
        iconColor: NSColor = .secondaryLabelColor,
        textColor: NSColor = .secondaryLabelColor,
        textFont: NSFont = .systemFont(ofSize: 12, weight: .medium),
        style: Style = .subtle,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 6,
        action: (() -> Void)? = nil
    ) {
        self.style = style
        self.action = action
        self.baseHorizontalPadding = horizontalPadding
        self.baseVerticalPadding = verticalPadding
        updateTrackingAreas()

        label.stringValue = text
        label.textColor = textColor
        label.font = textFont

        if let iconName {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = iconColor
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }

        topConstraint?.constant = verticalPadding
        bottomConstraint?.constant = -verticalPadding
        leadingConstraint?.constant = horizontalPadding
        trailingConstraint?.constant = -horizontalPadding

        updateAppearance(animated: false)
        needsLayout = true
        needsDisplay = true
    }

    private func updateAppearance(animated: Bool, duration: TimeInterval = Animation.hoverDuration) {
        let fillColor: NSColor
        let borderColor: NSColor

        switch style {
        case .subtle:
            let baseFill = AppKitSectionChrome.fillColor(for: effectiveAppearance)
            let baseBorder = AppKitSectionChrome.borderColor(for: effectiveAppearance)
            let boost: CGFloat = isPressing ? 0.055 : (isHovering ? 0.03 : 0)
            fillColor = baseFill.blended(withFraction: boost, of: .labelColor) ?? baseFill
            borderColor = baseBorder.blended(withFraction: boost, of: .labelColor) ?? baseBorder

        case .prominent(let baseColor):
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alpha: CGFloat
            if isPressing {
                alpha = dark ? 0.28 : 0.20
            } else if isHovering {
                alpha = dark ? 0.20 : 0.14
            } else {
                alpha = dark ? 0.15 : 0.10
            }
            fillColor = baseColor.withAlphaComponent(alpha)
            borderColor = baseColor.withAlphaComponent(isPressing ? 0.38 : 0.30)
        }

        let apply = {
            self.layer?.backgroundColor = fillColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.layer?.borderWidth = AppKitSectionChrome.borderWidth
        }

        guard animated, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            apply()
        }
    }
}

// MARK: - Progress pill

/// Vertical "label over a thin progress bar" pill for download/install states.
@MainActor
final class UpdaterProgressPillView: NSView {

    private enum Constants {
        static let width: CGFloat = 150
    }

    init(progress: Double, text: String, color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: text)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let barBackground = NSView()
        barBackground.wantsLayer = true
        barBackground.layer?.cornerRadius = 1.5
        barBackground.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        barBackground.translatesAutoresizingMaskIntoConstraints = false

        let barFill = NSView()
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 1.5
        barFill.layer?.backgroundColor = color.cgColor
        barFill.translatesAutoresizingMaskIntoConstraints = false

        barBackground.addSubview(barFill)
        NSLayoutConstraint.activate([
            barBackground.widthAnchor.constraint(equalToConstant: Constants.width),
            barBackground.heightAnchor.constraint(equalToConstant: 3),
            barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
            barFill.widthAnchor.constraint(equalToConstant: max(0, min(1, progress)) * Constants.width),
        ])

        let stack = NSStackView(views: [titleLabel, barBackground])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
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
}
