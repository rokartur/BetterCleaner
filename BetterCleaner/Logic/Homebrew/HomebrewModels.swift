import Foundation

// MARK: - `brew info --json=v2` decode layer
//
// Only the fields the UI needs are decoded; Homebrew's JSON has many more.

/// Top-level container for `brew info --json=v2`.
struct BrewInfoV2: Decodable {
    let formulae: [BrewFormula]
    let casks: [BrewCask]
}

struct BrewFormula: Decodable {
    let name: String
    let fullName: String?
    let desc: String?
    let homepage: String?
    let versions: Versions
    let installed: [InstalledVersion]
    let outdated: Bool
    let pinned: Bool
    let dependencies: [String]?
    let tap: String?

    struct Versions: Decodable { let stable: String? }

    struct InstalledVersion: Decodable {
        let version: String
        let installedAsDependency: Bool?
        let installedOnRequest: Bool?

        enum CodingKeys: String, CodingKey {
            case version
            case installedAsDependency = "installed_as_dependency"
            case installedOnRequest = "installed_on_request"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, desc, homepage, versions, installed, outdated, pinned, dependencies, tap
        case fullName = "full_name"
    }
}

struct BrewCask: Decodable {
    let token: String
    let fullToken: String?
    let tap: String?
    let name: [String]
    let desc: String?
    let homepage: String?
    let version: String?
    let installed: String?
    let outdated: Bool
    let autoUpdates: Bool?
    let dependencies: CaskDependencies?

    /// Casks declare dependencies as a nested object; we only surface formula deps.
    struct CaskDependencies: Decodable { let formula: [String]? }

    enum CodingKeys: String, CodingKey {
        case token, tap, name, desc, homepage, version, installed, outdated
        case fullToken = "full_token"
        case autoUpdates = "auto_updates"
        case dependencies = "depends_on"
    }
}

// MARK: - Unified UI model

/// One installed (or searchable) Homebrew package — a formula or a cask — flattened
/// for the list/detail UI. The `token` is the brew identifier (formula name or cask
/// token) used in every command; `displayName` is the human label.
struct HomebrewPackage {
    enum Kind { case formula, cask }

    let kind: Kind
    let token: String
    let displayName: String
    let description: String
    let homepage: String
    let installedVersion: String
    let latestVersion: String
    let isOutdated: Bool
    let isPinned: Bool
    /// `false` ⇒ pulled in only as another package's dependency (a non-leaf).
    let installedOnRequest: Bool
    /// Casks that update themselves report no reliable "outdated" state.
    let autoUpdates: Bool
    let tap: String
    let dependencies: [String]

    var isCask: Bool { kind == .cask }
    /// Stable identity for table reloads / selection restoration.
    var id: String { "\(isCask ? "cask" : "formula")-\(token)" }

    init(formula f: BrewFormula) {
        kind = .formula
        token = f.name
        displayName = f.name
        description = f.desc ?? ""
        homepage = f.homepage ?? ""
        installedVersion = f.installed.last?.version ?? ""
        latestVersion = f.versions.stable ?? ""
        isOutdated = f.outdated
        isPinned = f.pinned
        installedOnRequest = f.installed.last?.installedOnRequest ?? true
        autoUpdates = false
        tap = f.tap ?? ""
        dependencies = f.dependencies ?? []
    }

    init(cask c: BrewCask) {
        kind = .cask
        token = c.token
        displayName = c.name.first ?? c.token
        description = c.desc ?? ""
        homepage = c.homepage ?? ""
        installedVersion = c.installed ?? ""
        latestVersion = c.version ?? ""
        isOutdated = c.outdated
        isPinned = false
        installedOnRequest = true
        autoUpdates = c.autoUpdates ?? false
        tap = c.tap ?? ""
        dependencies = c.dependencies?.formula ?? []
    }
}

// MARK: - Services (`brew services list --json`)

struct ServiceInfo: Decodable {
    let name: String
    let status: String          // started | stopped | none | error | scheduled | unknown
    let user: String?
    let file: String?

    var id: String { name }
    var isRunning: Bool { status == "started" || status == "scheduled" }
}

// MARK: - Taps (`brew tap-info --installed --json`)

struct TapInfo: Decodable {
    let name: String
    let user: String?
    let repo: String?
    let official: Bool?
    let remote: String?
    let formulaNames: [String]?
    let caskTokens: [String]?

    var id: String { name }
    var packageCount: Int { (formulaNames?.count ?? 0) + (caskTokens?.count ?? 0) }

    enum CodingKeys: String, CodingKey {
        case name, user, repo, official, remote
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }
}

// MARK: - Selection passed from the master list to the detail pane

enum HomebrewSelection {
    case package(HomebrewPackage)
    case service(ServiceInfo)
    case tap(TapInfo)
}

/// The three master-list categories, in segmented-control order.
enum HomebrewCategory: Int, CaseIterable {
    case installed
    case services
    case taps

    var title: String {
        switch self {
        case .installed: return "Installed"
        case .services:  return "Services"
        case .taps:      return "Taps"
        }
    }
}
