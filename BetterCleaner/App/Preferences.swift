import AppKit
import Combine

/// How aggressively `FileMatcher` associates files with an app. Higher levels
/// trade more matches for more false positives.
enum SearchSensitivity: Int {
    case strict = 0
    case standard = 1
    case aggressive = 2
}

enum AppTheme: Int {
    case system = 0
    case light = 1
    case dark = 2

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide preferences, persisted to `UserDefaults` under the `BetterCleaner.`
/// prefix. `@Published` properties write through on `didSet`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let includeSystem = "BetterCleaner.includeSystemFiles"
        static let confirmDelete = "BetterCleaner.confirmBeforeDelete"
        static let extraPaths = "BetterCleaner.extraScanPaths"
        static let orphanExclusions = "BetterCleaner.orphanExclusions"
        static let userConditions = "BetterCleaner.userConditions"
        static let theme = "BetterCleaner.theme"
        static let sortBySize = "BetterCleaner.sortBySize"
        static let forceQuit = "BetterCleaner.completeUninstallForceQuit"
        static let resetPrivacy = "BetterCleaner.completeUninstallResetPrivacy"
        static let keychain = "BetterCleaner.completeUninstallKeychain"
    }

    /// File matching is always Aggressive — most thorough association.
    let searchSensitivity: SearchSensitivity = .aggressive
    @Published var includeSystemFiles: Bool {
        didSet { defaults.set(includeSystemFiles, forKey: Keys.includeSystem) }
    }
    @Published var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmDelete) }
    }
    @Published var sortBySize: Bool {
        didSet { defaults.set(sortBySize, forKey: Keys.sortBySize) }
    }
    @Published var extraScanPaths: [String] {
        didSet { defaults.set(extraScanPaths, forKey: Keys.extraPaths) }
    }
    @Published var orphanExclusions: [String] {
        didSet { defaults.set(orphanExclusions, forKey: Keys.orphanExclusions) }
    }
    /// User-defined include/exclude matching rules (persisted as JSON).
    @Published var userConditions: [UserCondition] {
        didSet {
            if let data = try? JSONEncoder().encode(userConditions) {
                defaults.set(data, forKey: Keys.userConditions)
            }
        }
    }
    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    // "Complete uninstall" extra steps. Default ON for the most thorough removal;
    // each is opt-out because some are irreversible (privacy re-grant, force-kill,
    // Keychain). File moves always stay Trash-recoverable.
    @Published var completeUninstallForceQuit: Bool {
        didSet { defaults.set(completeUninstallForceQuit, forKey: Keys.forceQuit) }
    }
    @Published var completeUninstallResetPrivacy: Bool {
        didSet { defaults.set(completeUninstallResetPrivacy, forKey: Keys.resetPrivacy) }
    }
    @Published var completeUninstallKeychain: Bool {
        didSet { defaults.set(completeUninstallKeychain, forKey: Keys.keychain) }
    }

    private init() {
        defaults.register(defaults: [
            // Scan /Library by default for a complete picture — removing system
            // files still needs an admin approval, and they're never auto-selected
            // unless strongly matched.
            Keys.includeSystem: true,
            Keys.confirmDelete: true,
            Keys.sortBySize: true,
            Keys.theme: AppTheme.system.rawValue,
            Keys.forceQuit: true,
            Keys.resetPrivacy: true,
            Keys.keychain: true,
        ])
        includeSystemFiles = defaults.bool(forKey: Keys.includeSystem)
        confirmBeforeDelete = defaults.bool(forKey: Keys.confirmDelete)
        sortBySize = defaults.bool(forKey: Keys.sortBySize)
        extraScanPaths = defaults.stringArray(forKey: Keys.extraPaths) ?? []
        orphanExclusions = defaults.stringArray(forKey: Keys.orphanExclusions) ?? []
        if let data = defaults.data(forKey: Keys.userConditions),
           let decoded = try? JSONDecoder().decode([UserCondition].self, from: data) {
            userConditions = decoded
        } else {
            userConditions = []
        }
        theme = AppTheme(rawValue: defaults.integer(forKey: Keys.theme)) ?? .system
        completeUninstallForceQuit = defaults.bool(forKey: Keys.forceQuit)
        completeUninstallResetPrivacy = defaults.bool(forKey: Keys.resetPrivacy)
        completeUninstallKeychain = defaults.bool(forKey: Keys.keychain)
    }

    var extraScanURLs: [URL] { extraScanPaths.map { URL(fileURLWithPath: $0) } }
    var orphanExclusionURLs: [URL] { orphanExclusions.map { URL(fileURLWithPath: $0) } }

    /// Enabled matching rules only (passed to the per-app scanner).
    var enabledConditions: [UserCondition] { userConditions.filter { $0.enabled } }

    /// Files the user explicitly assigned to an app — an enabled `include` rule
    /// pinned to a bundle id that matches a full path exactly. The orphan scan
    /// treats these as no-longer-orphaned (they now belong to that app).
    var assignedURLs: [URL] {
        enabledConditions
            .filter { $0.kind == .include && $0.target == .path && $0.op == .equals && $0.appScope != nil }
            .map { URL(fileURLWithPath: $0.value) }
    }

    func applyTheme() {
        NSApp.appearance = theme.appearance
    }
}
