import AppKit
import BetterSettings

enum SettingsTabID {
    static let general = "general"
    static let permissions = "permissions"
    static let exclusions = "exclusions"
    static let conditions = "conditions"
    static let about = "about"
}

/// Builds the BetterSettings configuration (tabs + content factory). Deep links
/// like `openSettings?name=general` resolve to these tab ids.
enum SettingsCatalog {
    @MainActor
    static func makeConfiguration() -> SettingsConfiguration {
        SettingsConfiguration(
            tabs: tabs,
            searchItems: searchItems,
            contentProvider: { tab, _ in
                switch tab.id {
                case SettingsTabID.general: return GeneralSettingsViewController()
                case SettingsTabID.permissions: return PermissionsSettingsViewController()
                case SettingsTabID.exclusions: return ExclusionsSettingsViewController()
                case SettingsTabID.conditions: return ConditionsSettingsViewController()
                default: return AboutSettingsViewController()
                }
            },
            searchPlaceholder: "Search",
            showDetailsDefaultsKey: "BetterCleaner.showSettingsDetails",
            tabUnloadPolicy: .balanced
        )
    }

    private static let searchItems: [SettingsSearchItem] = [
        SettingsSearchItem(
            id: "general.systemFiles", tabID: SettingsTabID.general, sectionAnchor: "scanning",
            title: "Include system files", tabTitle: "General", sectionTitle: "Scanning", keywords: ["Library", "admin"]),
        SettingsSearchItem(
            id: "general.confirmDelete", tabID: SettingsTabID.general, sectionAnchor: "scanning",
            title: "Confirm before deleting", tabTitle: "General", sectionTitle: "Scanning", keywords: ["trash", "remove"]),
        SettingsSearchItem(
            id: "general.stopHelpers", tabID: SettingsTabID.general, sectionAnchor: "uninstall",
            title: "Stop helper processes", tabTitle: "General", sectionTitle: "Complete Uninstall", keywords: ["force quit", "background"]),
        SettingsSearchItem(
            id: "general.resetPrivacy", tabID: SettingsTabID.general, sectionAnchor: "uninstall",
            title: "Reset privacy permissions", tabTitle: "General", sectionTitle: "Complete Uninstall", keywords: ["camera", "microphone", "TCC"]),
        SettingsSearchItem(
            id: "general.keychain", tabID: SettingsTabID.general, sectionAnchor: "uninstall",
            title: "Remove Keychain items", tabTitle: "General", sectionTitle: "Complete Uninstall", keywords: ["passwords", "credentials"]),
        SettingsSearchItem(
            id: "general.updateInterval", tabID: SettingsTabID.general, sectionAnchor: "updates",
            title: "Check for updates", tabTitle: "General", sectionTitle: "Updates", keywords: ["daily", "weekly", "release"]),
        SettingsSearchItem(
            id: "general.preReleases", tabID: SettingsTabID.general, sectionAnchor: "updates",
            title: "Include pre-releases", tabTitle: "General", sectionTitle: "Updates", keywords: ["beta", "preview"]),
        SettingsSearchItem(
            id: "permissions.fullDiskAccess", tabID: SettingsTabID.permissions, sectionAnchor: "permissions",
            title: "Full Disk Access", tabTitle: "Permissions", sectionTitle: "Permissions", keywords: ["privacy", "protected files"]),
        SettingsSearchItem(
            id: "permissions.admin", tabID: SettingsTabID.permissions, sectionAnchor: "permissions",
            title: "Administrator Password", tabTitle: "Permissions", sectionTitle: "Permissions", keywords: ["sudo", "system files"]),
        SettingsSearchItem(
            id: "exclusions.locations", tabID: SettingsTabID.exclusions, sectionAnchor: "extra-roots",
            title: "Extra Scan Locations", tabTitle: "Exclusions", sectionTitle: "Extra Scan Locations", keywords: ["folder", "applications"]),
        SettingsSearchItem(
            id: "exclusions.paths", tabID: SettingsTabID.exclusions, sectionAnchor: "exclusions",
            title: "Scan Exclusions", tabTitle: "Exclusions", sectionTitle: "Scan Exclusions", keywords: ["ignore", "skip", "folder"]),
        SettingsSearchItem(
            id: "conditions.rules", tabID: SettingsTabID.conditions, sectionAnchor: "rules",
            title: "Matching Rules", tabTitle: "Rules", sectionTitle: "Matching Rules", keywords: ["conditions", "cleanup"]),
        SettingsSearchItem(
            id: "about.source", tabID: SettingsTabID.about, sectionAnchor: "links",
            title: "Source code", tabTitle: "About", sectionTitle: "About", keywords: ["GitHub", "repository"]),
    ]

    private static var tabs: [SettingsTab] {
        [
            SettingsTab(id: SettingsTabID.general, title: "General", icon: "gearshape",
                        iconStyle: .solid(SettingsColor(hex: 0x8E8E93))),
            SettingsTab(id: SettingsTabID.permissions, title: "Permissions", icon: "lock.shield",
                        iconStyle: .solid(SettingsColor(hex: 0x30B0C7))),
            SettingsTab(id: SettingsTabID.exclusions, title: "Exclusions", icon: "folder.badge.minus",
                        iconStyle: .solid(SettingsColor(hex: 0xFF9500))),
            SettingsTab(id: SettingsTabID.conditions, title: "Rules", icon: "slider.horizontal.3",
                        iconStyle: .solid(SettingsColor(hex: 0xAF52DE))),
            SettingsTab(id: SettingsTabID.about, title: "About", icon: "info.circle",
                        iconStyle: .solid(SettingsColor(hex: 0x5856D6))),
        ]
    }
}
