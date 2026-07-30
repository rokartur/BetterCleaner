import Foundation

// MARK: - `brew info --json=v2` decode layer
//
// Only the fields the UI needs are decoded; Homebrew's JSON has many more.

/// Top-level container for `brew info --json=v2`.
struct BrewInfoV2: Decodable {
    let formulae: [BrewFormula]
    let casks: [BrewCask]
}

struct BrewOutdatedV2: Decodable {
    let formulae: [Package]
    let casks: [Package]

    struct Package: Decodable {
        let name: String
        let fullName: String?
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool?

        enum CodingKeys: String, CodingKey {
            case name, pinned
            case fullName = "full_name"
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }
    }
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
    let caveats: String?
    let license: String?
    let deprecated: Bool?
    let deprecationReason: String?
    let disabled: Bool?
    let disableReason: String?
    let requirements: [Requirement]?
    let service: BrewService?

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

    struct Requirement: Decodable {
        let name: String
        let version: String?

        var text: String {
            guard let version, !version.isEmpty else { return name }
            return "\(name) \(version)"
        }
    }

    /// Service definitions have several command-specific shapes. The UI only needs
    /// to know whether one exists, so decoding their internals would add dead API.
    struct BrewService: Decodable {
        init(from decoder: Decoder) throws {}
    }

    enum CodingKeys: String, CodingKey {
        case name, desc, homepage, versions, installed, outdated, pinned, dependencies, tap
        case caveats, license, deprecated, disabled, requirements, service
        case fullName = "full_name"
        case deprecationReason = "deprecation_reason"
        case disableReason = "disable_reason"
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
    let bundleVersion: String?
    let installed: String?
    let outdated: Bool
    let pinned: Bool?
    let autoUpdates: Bool?
    let dependencies: CaskDependencies?
    let artifacts: [Artifact]?
    let caveats: String?
    let license: String?
    let deprecated: Bool?
    let deprecationReason: String?
    let disabled: Bool?
    let disableReason: String?

    struct Artifact: Decodable {
        let app: [String]?
        let target: String?
    }

    /// Casks declare dependencies as a nested object. Keep only formula dependencies
    /// and the macOS constraint surfaced by the detail UI.
    struct CaskDependencies: Decodable {
        let formula: [String]?
        let macOS: [String: [String]]?

        enum CodingKeys: String, CodingKey {
            case formula
            case macOS = "macos"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formula = try? container.decode([String].self, forKey: .formula)
            macOS = try? container.decode([String: [String]].self, forKey: .macOS)
        }
    }

    enum CodingKeys: String, CodingKey {
        case token, tap, name, desc, homepage, version, installed, outdated, pinned
        case artifacts, caveats, license, deprecated, disabled
        case bundleVersion = "bundle_version"
        case fullToken = "full_token"
        case autoUpdates = "auto_updates"
        case dependencies = "depends_on"
        case deprecationReason = "deprecation_reason"
        case disableReason = "disable_reason"
    }
}

// MARK: - Unified UI model

/// One installed (or searchable) Homebrew package — a formula or a cask — flattened
/// for the list/detail UI. `token` is the short display identifier, `commandToken`
/// is the unambiguous brew argument, and `displayName` is the human label.
struct HomebrewPackage {
    enum Kind: String, Hashable, Codable { case formula, cask }

    struct AppArtifact: Hashable {
        let source: String
        let target: String?

        var bundleName: String {
            URL(fileURLWithPath: target ?? source).lastPathComponent
        }

        var actualURL: URL {
            let path: String
            if let target, !target.isEmpty { path = target.expandingTildeInPath }
            else { path = "/Applications/\(source)" }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    let kind: Kind
    /// Short display token (`wget`, `firefox`).
    let token: String
    /// Unambiguous token passed to brew (`user/tap/package` for third-party taps).
    let commandToken: String
    let displayName: String
    let description: String
    let homepage: String
    var installedVersion: String
    var latestVersion: String
    let latestBundleVersion: String
    var isOutdated: Bool
    var isPinned: Bool
    /// `false` ⇒ pulled in only as another package's dependency (a non-leaf).
    let installedOnRequest: Bool
    /// Casks that update themselves report no reliable "outdated" state.
    let autoUpdates: Bool
    let tap: String
    let dependencies: [String]
    let appArtifacts: [AppArtifact]
    let caveats: String
    let license: String
    let isDeprecated: Bool
    let deprecationReason: String
    let isDisabled: Bool
    let disableReason: String
    let requirements: [String]
    let hasService: Bool

    var isCask: Bool { kind == .cask }
    var reference: HomebrewPackageRef { HomebrewPackageRef(token: commandToken, kind: kind) }
    var actualAppURLs: [URL] { appArtifacts.map(\.actualURL) }
    /// Stable identity for table reloads / selection restoration.
    var id: String { "\(kind.rawValue)-\(commandToken)" }

    init(formula f: BrewFormula) {
        kind = .formula
        token = f.name
        commandToken = f.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? f.name
        displayName = f.name
        description = f.desc ?? ""
        homepage = f.homepage ?? ""
        installedVersion = f.installed.last?.version ?? ""
        latestVersion = f.versions.stable ?? ""
        latestBundleVersion = ""
        isOutdated = f.outdated
        isPinned = f.pinned
        installedOnRequest = f.installed.last?.installedOnRequest ?? true
        autoUpdates = false
        tap = f.tap ?? ""
        dependencies = f.dependencies ?? []
        appArtifacts = []
        caveats = f.caveats ?? ""
        license = f.license ?? ""
        isDeprecated = f.deprecated ?? false
        deprecationReason = f.deprecationReason ?? ""
        isDisabled = f.disabled ?? false
        disableReason = f.disableReason ?? ""
        requirements = f.requirements?.map(\.text) ?? []
        hasService = f.service != nil
    }

    init(cask c: BrewCask) {
        kind = .cask
        token = c.token
        commandToken = c.fullToken.flatMap { $0.isEmpty ? nil : $0 } ?? c.token
        displayName = c.name.first ?? c.token
        description = c.desc ?? ""
        homepage = c.homepage ?? ""
        installedVersion = c.installed ?? ""
        latestVersion = c.version ?? ""
        latestBundleVersion = c.bundleVersion ?? ""
        isOutdated = c.outdated
        isPinned = c.pinned ?? false
        installedOnRequest = true
        autoUpdates = c.autoUpdates ?? false
        tap = c.tap ?? ""
        dependencies = c.dependencies?.formula ?? []
        appArtifacts = c.artifacts?.flatMap { artifact in
            artifact.app?.map { AppArtifact(source: $0, target: artifact.target) } ?? []
        } ?? []
        caveats = c.caveats ?? ""
        license = c.license ?? ""
        isDeprecated = c.deprecated ?? false
        deprecationReason = c.deprecationReason ?? ""
        isDisabled = c.disabled ?? false
        disableReason = c.disableReason ?? ""
        requirements = c.dependencies?.macOS?
            .sorted { $0.key < $1.key }
            .map { "macOS \($0.key) \($0.value.joined(separator: ", "))" } ?? []
        hasService = false
    }
}

struct HomebrewPackageRef: Hashable, Codable {
    let token: String
    let kind: HomebrewPackage.Kind

    var isCask: Bool { kind == .cask }
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
    let installed: Bool
    let user: String?
    let repo: String?
    let official: Bool?
    let remote: String?
    let formulaNames: [String]?
    let caskTokens: [String]?

    var id: String { name }
    var packageCount: Int { (formulaNames?.count ?? 0) + (caskTokens?.count ?? 0) }
    var packageRefs: [HomebrewPackageRef] {
        (formulaNames ?? []).map { HomebrewPackageRef(token: $0, kind: .formula) }
            + (caskTokens ?? []).map { HomebrewPackageRef(token: $0, kind: .cask) }
    }

    enum CodingKeys: String, CodingKey {
        case name, installed, user, repo, official, remote
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }
}

private extension String {
    var expandingTildeInPath: String { (self as NSString).expandingTildeInPath }
}

// MARK: - Selection passed from the master list to the detail pane

enum HomebrewSelection {
    case package(HomebrewPackage)
    case packageReference(HomebrewPackageRef)
    case service(ServiceInfo)
    case tap(TapInfo)
}

/// The master-list categories shown in the Homebrew navigation group.
enum HomebrewCategory: Int, CaseIterable {
    case installed
    case available
    case services
    case taps

    var title: String {
        switch self {
        case .installed: return "Installed"
        case .available: return "Available"
        case .services:  return "Services"
        case .taps:      return "Taps"
        }
    }
}
