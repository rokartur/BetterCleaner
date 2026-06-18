import AppKit

/// One entry in the left navigation sidebar.
struct NavSection {
    let id: String
    let title: String
    /// SF Symbol, rendered as a template image tinted with the system accent in
    /// the sidebar row.
    let icon: String
    let enabled: Bool

    init(id: String, title: String, icon: String, enabled: Bool) {
        self.id = id
        self.title = title
        self.icon = icon
        self.enabled = enabled
    }
}

/// The sidebar's page catalog, split into Cleanup / Tools / System groups. Icons
/// are plain monochrome SF Symbols (no colored tiles) so the sidebar reads native.
enum NavCatalog {
    static let cleanup: [NavSection] = [
        NavSection(id: "applications", title: "Applications", icon: "square.grid.2x2", enabled: true),
        NavSection(id: "junk", title: "System Junk", icon: "trash", enabled: true),
        NavSection(id: "orphaned", title: "Orphaned Files", icon: "folder.badge.questionmark", enabled: true),
    ]

    static let tools: [NavSection] = [
        NavSection(id: "pkg", title: "Packages", icon: "shippingbox", enabled: true),
        NavSection(id: "devenv", title: "Development", icon: "wrench.and.screwdriver", enabled: true),
    ]

    static let system: [NavSection] = [
        NavSection(id: "history", title: "Delete History", icon: "clock.arrow.circlepath", enabled: true),
    ]

    /// The grouped sidebar order — each group renders under its own header.
    static let groups: [(title: String, items: [NavSection])] = [
        ("Cleanup", cleanup),
        ("Tools", tools),
        ("System", system),
    ]

    /// Full sidebar order, flat.
    static var all: [NavSection] { cleanup + tools + system }

    static func section(id: String) -> NavSection? {
        all.first { $0.id == id }
    }
}
