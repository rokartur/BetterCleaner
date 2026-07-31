import Foundation

/// Finds application bundles that Homebrew can safely adopt. Suggestions require an
/// exact cask `app` artifact match; a manually entered token goes through the same
/// validation before `brew install --cask --adopt` is allowed to run.
enum HomebrewAdopter {
    struct Candidate {
        let app: InstalledApp

        var appName: String { app.name }
        var appPath: String { app.url.path }
    }

    struct Match {
        let package: HomebrewPackage
        let versionCompatible: Bool
    }

    enum ValidationError: LocalizedError {
        case invalidToken
        case unknownCask(String)
        case deprecated(String)
        case disabled(String)
        case artifactMismatch(app: String, cask: String)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "Enter a valid Homebrew cask token."
            case .unknownCask(let token):
                return "Homebrew couldn't find the cask “\(token)”."
            case .deprecated(let reason):
                return reason.isEmpty ? "This cask is deprecated." : "This cask is deprecated: \(reason)"
            case .disabled(let reason):
                return reason.isEmpty ? "This cask is disabled." : "This cask is disabled: \(reason)"
            case .artifactMismatch(let app, let cask):
                return "\(cask) doesn't install the \(app) artifact."
            }
        }
    }

    /// Every non-system app that is not already represented by an installed cask's
    /// exact app artifact. Matching to available casks happens lazily after selection.
    static func candidates() throws -> [Candidate] {
        guard HomebrewEnvironment.isInstalled else { throw HomebrewServiceError.notInstalled }
        return candidates(apps: AppFinder.installedApps(), installedPackages: try HomebrewService.installedPackages())
    }

    static func candidates(apps: [InstalledApp], installedPackages: [HomebrewPackage]) -> [Candidate] {
        let installedCasks = installedPackages.filter(\.isCask)
        let managedPaths = Set(installedCasks.flatMap(\.actualAppURLs).map(normalizedPath))

        return apps
            .filter { app in
                !app.isSystem
                    && !managedPaths.contains(normalizedPath(app.url))
            }
            .map(Candidate.init(app:))
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Search by the app's real bundle names, then keep only exact artifact matches.
    static func suggestions(for app: InstalledApp) throws -> [Match] {
        var refs = Set<HomebrewPackageRef>()
        for term in searchTerms(for: app) {
            refs.formUnion(try HomebrewService.search(term, kind: .cask))
        }

        var matches: [Match] = []
        var firstLookupError: Error?
        for ref in refs.sorted(by: { $0.token < $1.token }) {
            do {
                if let package = try HomebrewService.info(ref), let match = match(app: app, package: package) {
                    matches.append(match)
                }
            } catch {
                if firstLookupError == nil { firstLookupError = error }
            }
        }
        if matches.isEmpty, let firstLookupError { throw firstLookupError }
        return matches.sorted {
            if $0.versionCompatible != $1.versionCompatible { return $0.versionCompatible }
            return $0.package.displayName.localizedCaseInsensitiveCompare($1.package.displayName) == .orderedAscending
        }
    }

    static func validateManualToken(_ token: String, for app: InstalledApp) throws -> Match {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.hasPrefix("-") else { throw ValidationError.invalidToken }
        guard let package = try HomebrewService.info(HomebrewPackageRef(token: token, kind: .cask)) else {
            throw ValidationError.unknownCask(token)
        }
        if package.isDeprecated { throw ValidationError.deprecated(package.deprecationReason) }
        if package.isDisabled { throw ValidationError.disabled(package.disableReason) }
        guard matchesArtifact(app: app, package: package) else {
            throw ValidationError.artifactMismatch(app: app.url.lastPathComponent, cask: package.displayName)
        }
        return Match(package: package, versionCompatible: versionCompatible(app: app, package: package))
    }

    static func match(app: InstalledApp, package: HomebrewPackage) -> Match? {
        guard package.isCask, !package.isDeprecated, !package.isDisabled,
              matchesArtifact(app: app, package: package) else { return nil }
        return Match(package: package, versionCompatible: versionCompatible(app: app, package: package))
    }

    static func matchesArtifact(app: InstalledApp, package: HomebrewPackage) -> Bool {
        let appPath = normalizedPath(app.url)
        return package.appArtifacts.contains { normalizedPath($0.actualURL) == appPath }
    }

    static func versionCompatible(app: InstalledApp, package: HomebrewPackage) -> Bool {
        if package.autoUpdates { return true }
        guard let installed = app.shortVersion, !installed.isEmpty, !package.latestVersion.isEmpty else { return false }
        return HomebrewVersion.compare(installed, package.latestVersion) == .orderedSame
    }

    /// Lowercase, non-alphanumerics collapsed to single hyphens — the common cask
    /// token shape (e.g. "Visual Studio Code" → "visual-studio-code").
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func searchTerms(for app: InstalledApp) -> [String] {
        let terms = [app.url.deletingPathExtension().lastPathComponent, app.name, app.bundleName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
