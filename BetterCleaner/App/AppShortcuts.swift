import AppKit
import BetterShortcuts

extension BetterShortcuts.Name {
    static let toggleMainWindow = Self("toggleMainWindow")
    static let refreshApps = Self("refreshApps")
    static let scanOrphaned = Self("scanOrphaned")
}

/// Wires global keyboard shortcuts to app actions at launch.
enum AppShortcuts {
    /// All user-recordable shortcut names, in settings-display order.
    static let all: [BetterShortcuts.Name] = [.toggleMainWindow, .refreshApps, .scanOrphaned]

    static func title(for name: BetterShortcuts.Name) -> String {
        switch name {
        case .toggleMainWindow: return "Show BetterCleaner"
        case .refreshApps: return "Refresh app list"
        case .scanOrphaned: return "Scan orphaned files"
        default: return name.rawValue
        }
    }

    static func install() {
        BetterShortcuts.recorderPolicy = .standard
        BetterShortcuts.displayName = { name in
            switch name {
            case .toggleMainWindow: return "Show BetterCleaner"
            case .refreshApps: return "Refresh app list"
            case .scanOrphaned: return "Scan orphaned files"
            default: return name.rawValue
            }
        }

        BetterShortcuts.onKeyDown(for: .toggleMainWindow) {
            MainActor.assumeIsolated { AppCoordinator.shared.showMainWindow() }
        }
        BetterShortcuts.onKeyDown(for: .refreshApps) {
            MainActor.assumeIsolated { AppCoordinator.shared.refreshApps() }
        }
        BetterShortcuts.onKeyDown(for: .scanOrphaned) {
            MainActor.assumeIsolated { AppCoordinator.shared.showOrphaned() }
        }
    }
}
