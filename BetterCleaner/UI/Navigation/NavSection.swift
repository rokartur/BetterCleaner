import AppKit

/// One entry in the left navigation sidebar.
struct NavSection {
    let id: String
    let title: String
    /// SF Symbol rendered white inside the gradient badge.
    let icon: String
    let enabled: Bool
    /// Badge tint — the macOS-System-Settings-style colored icon tile.
    let tint: NSColor

    init(id: String, title: String, icon: String, enabled: Bool, tint: NSColor) {
        self.id = id
        self.title = title
        self.icon = icon
        self.enabled = enabled
        self.tint = tint
    }
}

/// The sidebar's section catalog, grouped into Cleanup + Tools. Each section
/// carries a colored badge tint matching the BetterSettings sidebar look.
enum NavCatalog {
    // System dynamic colors (not fixed hex) so each badge uses Apple's exact
    // palette and adapts to light/dark, matching the System Settings icon tiles.
    static let cleanup: [NavSection] = [
        NavSection(id: "applications", title: "Applications", icon: "square.grid.2x2.fill", enabled: true, tint: .systemBlue),
        NavSection(id: "junk", title: "System Junk", icon: "trash.fill", enabled: true, tint: .systemOrange),
        NavSection(id: "orphaned", title: "Orphaned Files", icon: "folder.fill.badge.questionmark", enabled: true, tint: .systemPurple),
    ]

    static let tools: [NavSection] = [
        NavSection(id: "pkg", title: "Packages", icon: "shippingbox.fill", enabled: true, tint: .systemIndigo),
        NavSection(id: "devenv", title: "Development", icon: "wrench.and.screwdriver.fill", enabled: true, tint: .systemRed),
    ]

    static let system: [NavSection] = [
        NavSection(id: "history", title: "Delete History", icon: "clock.arrow.circlepath", enabled: true, tint: .systemTeal),
    ]

    /// Full sidebar order, flat.
    static var all: [NavSection] { cleanup + tools + system }

    static func section(id: String) -> NavSection? {
        all.first { $0.id == id }
    }
}
