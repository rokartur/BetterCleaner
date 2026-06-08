import AppKit
import BetterSettings

enum SettingsTabID {
    static let general = "general"
    static let permissions = "permissions"
    static let exclusions = "exclusions"
    static let conditions = "conditions"
    static let appearance = "appearance"
    static let shortcuts = "shortcuts"
    static let update = "update"
    static let about = "about"
}

/// Builds the BetterSettings configuration (tabs + content factory). Deep links
/// like `openSettings?name=general` resolve to these tab ids.
enum SettingsCatalog {
    @MainActor
    static func makeConfiguration() -> SettingsConfiguration {
        SettingsConfiguration(
            tabs: tabs,
            searchItems: [],
            contentProvider: { tab, _ in
                switch tab.id {
                case SettingsTabID.general: return GeneralSettingsViewController()
                case SettingsTabID.permissions: return PermissionsSettingsViewController()
                case SettingsTabID.exclusions: return ExclusionsSettingsViewController()
                case SettingsTabID.conditions: return ConditionsSettingsViewController()
                case SettingsTabID.appearance: return AppearanceSettingsViewController()
                case SettingsTabID.shortcuts: return ShortcutsSettingsViewController()
                case SettingsTabID.update: return UpdateSettingsViewController()
                default: return AboutSettingsViewController()
                }
            },
            searchPlaceholder: "Search",
            showDetailsDefaultsKey: "BetterCleaner.showSettingsDetails",
            tabUnloadPolicy: .balanced
        )
    }

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
            SettingsTab(id: SettingsTabID.appearance, title: "Appearance", icon: "paintbrush",
                        iconStyle: .solid(SettingsColor(hex: 0xFF2D55))),
            SettingsTab(id: SettingsTabID.shortcuts, title: "Shortcuts", icon: "command",
                        iconStyle: .solid(SettingsColor(hex: 0x007AFF))),
            SettingsTab(id: SettingsTabID.update, title: "Update", icon: "arrow.down.circle",
                        iconStyle: .solid(SettingsColor(hex: 0x34C759))),
            SettingsTab(id: SettingsTabID.about, title: "About", icon: "info.circle",
                        iconStyle: .solid(SettingsColor(hex: 0x5856D6))),
        ]
    }
}
