import AppKit

/// One entry in the left navigation sidebar.
struct NavSection {
    let id: String
    let title: String
    /// SF Symbol rendered white inside the gradient icon badge.
    let icon: String
    let enabled: Bool
    /// Badge tile color — the macOS-System-Settings / BetterSettings colored icon
    /// badge (white symbol on a rounded gradient tile).
    let color: NSColor

    init(id: String, title: String, icon: String, enabled: Bool, color: NSColor) {
        self.id = id
        self.title = title
        self.icon = icon
        self.enabled = enabled
        self.color = color
    }
}

/// The sidebar's page catalog, split into Cleanup / Tools / System groups. Each
/// page carries a colored badge tile, rendered 1:1 with the BetterSettings tab
/// list (white SF Symbol on a rounded gradient tile).
enum NavCatalog {
    static let cleanup: [NavSection] = [
        NavSection(id: "applications", title: "Applications", icon: "square.grid.2x2.fill", enabled: true, color: .systemBlue),
        NavSection(id: "junk", title: "System Junk", icon: "trash.fill", enabled: true, color: .systemOrange),
        NavSection(id: "orphaned", title: "Orphaned Files", icon: "folder.fill.badge.questionmark", enabled: true, color: .systemPurple),
    ]

    static let tools: [NavSection] = [
        NavSection(id: "pkg", title: "Packages", icon: "shippingbox.fill", enabled: true, color: .systemIndigo),
        NavSection(id: "devenv", title: "Development", icon: "hammer.fill", enabled: true, color: .systemRed),
    ]

    /// Homebrew management — its own group, one row per category (TapHouse-style).
    static let homebrew: [NavSection] = [
        NavSection(id: "brew.installed", title: "Installed", icon: "shippingbox.fill", enabled: true, color: .systemGreen),
        NavSection(id: "brew.services", title: "Services", icon: "gearshape.2.fill", enabled: true, color: .systemTeal),
        NavSection(id: "brew.taps", title: "Taps", icon: "arrow.triangle.branch", enabled: true, color: .systemBlue),
    ]

    static let system: [NavSection] = [
        NavSection(id: "history", title: "Delete History", icon: "clock.arrow.circlepath", enabled: true, color: .systemTeal),
    ]

    /// The grouped sidebar order — each group renders under its own header.
    static let groups: [(title: String, items: [NavSection])] = [
        ("Cleanup", cleanup),
        ("Tools", tools),
        ("Homebrew", homebrew),
        ("System", system),
    ]

    /// Full sidebar order, flat.
    static var all: [NavSection] { cleanup + tools + homebrew + system }

    static func section(id: String) -> NavSection? {
        all.first { $0.id == id }
    }
}
