/// One entry in the native source-list sidebar.
struct NavSection {
    let id: String
    let title: String
    let icon: String
    let enabled: Bool
}

/// The sidebar's page catalog, split into Cleanup / Tools / System groups.
enum NavCatalog {
    static let cleanup: [NavSection] = [
        NavSection(id: "applications", title: "Applications", icon: "square.grid.2x2", enabled: true),
        NavSection(id: "junk", title: "System Junk", icon: "trash", enabled: true),
        NavSection(id: "orphaned", title: "Orphaned Files", icon: "folder.badge.questionmark", enabled: true),
    ]

    static let tools: [NavSection] = [
        NavSection(id: "pkg", title: "Packages", icon: "shippingbox", enabled: true),
        NavSection(id: "devenv", title: "Development", icon: "hammer", enabled: true),
        NavSection(id: "search", title: "File Search", icon: "magnifyingglass", enabled: true),
    ]

    /// Homebrew is one destination, not six. The four browsable categories
    /// (Installed / Available / Services / Taps) switch inside the list column
    /// where the user already is, and Auto Update / Maintenance live in that
    /// column's ⋯ menu next to the other maintenance commands. Every page id below
    /// still routes — only the sidebar rows are gone, so deep links and the Finder
    /// extension are unaffected.
    static let homebrew: [NavSection] = [
        NavSection(id: "brew.installed", title: "Homebrew", icon: "shippingbox", enabled: true),
    ]

    static let system: [NavSection] = [
        NavSection(id: "history", title: "Delete History", icon: "clock.arrow.circlepath", enabled: true),
    ]

    /// Page ids that are reachable by routing but own no sidebar row (they're
    /// reached from the Homebrew column's ⋯ menu or its category switcher).
    static let unlisted: [NavSection] = [
        NavSection(id: "brew.available", title: "Available", icon: "square.grid.2x2", enabled: true),
        NavSection(id: "brew.services", title: "Services", icon: "gearshape.2", enabled: true),
        NavSection(id: "brew.taps", title: "Taps", icon: "arrow.triangle.branch", enabled: true),
        NavSection(id: "brew.autoupdate", title: "Auto Update", icon: "clock.arrow.2.circlepath", enabled: true),
        NavSection(id: "brew.maintenance", title: "Maintenance", icon: "wrench.and.screwdriver", enabled: true),
    ]

    /// The grouped sidebar order — each group renders under its own header.
    /// Homebrew's single row joins Tools: it's one more tool, not a third of the app.
    static let groups: [(title: String, items: [NavSection])] = [
        ("Cleanup", cleanup),
        ("Tools", tools + homebrew),
        ("System", system),
    ]

    /// Full sidebar order, flat.
    static var all: [NavSection] { cleanup + tools + homebrew + system }

    /// Every routable page, including the ones with no sidebar row.
    static var routable: [NavSection] { all + unlisted }

    static func section(id: String) -> NavSection? {
        routable.first { $0.id == id }
    }
}
