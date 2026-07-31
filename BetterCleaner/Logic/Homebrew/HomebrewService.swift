import Foundation

enum HomebrewServiceError: LocalizedError, Equatable {
    case notInstalled
    case commandFailed(arguments: [String], status: Int32, message: String)
    case invalidResponse(arguments: [String])

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Homebrew is not installed."
        case .commandFailed(let arguments, let status, let message):
            let detail = message.isEmpty ? "brew exited with status \(status)." : message
            return "brew \(arguments.joined(separator: " ")) failed: \(detail)"
        case .invalidResponse(let arguments):
            return "brew \(arguments.joined(separator: " ")) returned an unreadable response."
        }
    }
}

/// Read-only Homebrew queries — installed packages, services, taps, search, single-
/// package info, dependency trees, and maintenance previews. Every method shells out
/// to `brew` through `CommandRunner` and parses JSON / text.
///
/// Non-isolated: call off the main thread (mirrors `PackageScanner`). Command and
/// decoding failures are thrown so the UI never presents an error as an empty result.
enum HomebrewService {
    // MARK: - Installed packages

    /// Installed formulae + casks, unified and sorted by display name.
    static func installedPackages() throws -> [HomebrewPackage] {
        let arguments = ["info", "--json=v2", "--installed"]
        let out = try run(arguments)
        let info = try decode(BrewInfoV2.self, out.stdout, arguments: arguments)
        let packages = info.formulae.map(HomebrewPackage.init(formula:))
            + info.casks.map(HomebrewPackage.init(cask:))
        let outdatedArguments = ["outdated", "--json=v2", "--greedy"]
        let outdated = try decode(BrewOutdatedV2.self, run(outdatedArguments).stdout,
                                  arguments: outdatedArguments)
        return mergeOutdated(packages, outdated: outdated).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func mergeOutdated(_ source: [HomebrewPackage], outdated: BrewOutdatedV2,
                              versionReader: (HomebrewPackage) -> (short: String?, build: String?)? = HomebrewService.actualAppVersion) -> [HomebrewPackage] {
        var formulae: [String: BrewOutdatedV2.Package] = [:]
        var casks: [String: BrewOutdatedV2.Package] = [:]
        for update in outdated.formulae {
            formulae[update.name] = update
            if let fullName = update.fullName { formulae[fullName] = update }
        }
        for update in outdated.casks {
            casks[update.name] = update
            if let fullName = update.fullName { casks[fullName] = update }
        }
        return source.map { original in
            var package = original
            package.isOutdated = false
            let updates = package.isCask ? casks : formulae
            let update = updates[package.commandToken] ?? updates[package.token]
            guard let update else { return package }
            package.latestVersion = update.currentVersion
            package.isPinned = update.pinned ?? package.isPinned
            if package.isCask {
                let actual = versionReader(package)
                if let short = actual?.short, !short.isEmpty,
                   package.installedVersion.isEmpty
                    || HomebrewVersion.compare(short, package.installedVersion) == .orderedDescending {
                    package.installedVersion = short
                }
                package.isOutdated = !HomebrewVersion.isAtLeast(package.installedVersion, update.currentVersion)
                let latestBuild = package.latestBundleVersion.isEmpty
                    ? HomebrewVersion.buildPart(update.currentVersion)
                    : package.latestBundleVersion
                let installedBuild = actual?.build ?? HomebrewVersion.buildPart(package.installedVersion)
                if !package.isOutdated,
                   update.currentVersion.caseInsensitiveCompare("latest") != .orderedSame,
                   HomebrewVersion.compare(package.installedVersion, update.currentVersion) == .orderedSame,
                   let installedBuild, !installedBuild.isEmpty,
                   let latestBuild, !latestBuild.isEmpty {
                    package.isOutdated = HomebrewVersion.compare(installedBuild, latestBuild) == .orderedAscending
                }
            } else {
                package.isOutdated = true
            }
            return package
        }
    }

    private static func actualAppVersion(_ package: HomebrewPackage) -> (short: String?, build: String?)? {
        for url in package.actualAppURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let bundle = Bundle(url: url) else { continue }
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            if short?.isEmpty == false || build?.isEmpty == false { return (short, build) }
        }
        return nil
    }

    // MARK: - Services

    static func services() throws -> [ServiceInfo] {
        let arguments = ["services", "list", "--json"]
        let out = try run(arguments)
        let list = try decode([ServiceInfo].self, out.stdout, arguments: arguments)
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Taps

    static func taps() throws -> [TapInfo] {
        let arguments = ["tap-info", "--installed", "--json"]
        return try parseTaps(run(arguments).stdout, arguments: arguments)
    }

    // MARK: - Search & single-package info

    static func availablePackages() throws -> [HomebrewPackageRef] {
        let formulae = parseNames(try run(["formulae"]).stdout)
            .map { HomebrewPackageRef(token: $0, kind: .formula) }
        let casks = parseNames(try run(["casks"]).stdout)
            .map { HomebrewPackageRef(token: $0, kind: .cask) }
        return Array(Set(formulae + casks)).sorted {
            $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending
        }
    }

    /// Native Homebrew description search. Section headers retain formula/cask kind,
    /// avoiding the ambiguous token-only result returned by a combined `brew search`.
    static func searchWithDescriptions(_ query: String) throws -> [HomebrewPackageRef: String] {
        // A leading "-" would reach brew as a flag (e.g. `--eval-all`), not a query.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return [:] }
        do {
            return parseDescriptionSearch(try run(["search", "--desc", trimmed]).stdout)
        } catch let error as HomebrewServiceError {
            if case .commandFailed(_, _, let message) = error,
               isNoSearchResults(message) { return [:] }
            throw error
        }
    }

    static func parseDescriptionSearch(_ text: String) -> [HomebrewPackageRef: String] {
        var kind: HomebrewPackage.Kind?
        var results: [HomebrewPackageRef: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "==> Formulae" { kind = .formula; continue }
            if line == "==> Casks" { kind = .cask; continue }
            guard let kind, let colon = line.firstIndex(of: ":") else { continue }
            let token = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let description = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            results[HomebrewPackageRef(token: token, kind: kind)] = description
        }
        return results
    }

    /// Names matching `query` across formulae and casks (`brew search`). Returns the
    /// raw tokens; the caller fetches descriptions lazily via `info(_:)`.
    static func search(_ query: String) throws -> [HomebrewPackageRef] {
        try search(query, kind: .formula) + search(query, kind: .cask)
    }

    static func search(_ query: String, kind: HomebrewPackage.Kind) throws -> [HomebrewPackageRef] {
        // A leading "-" would reach brew as a flag (e.g. `--eval-all`), not a query.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return [] }
        let flag = kind == .cask ? "--cask" : "--formula"
        do {
            return parseNames(try run(["search", flag, trimmed]).stdout)
                .map { HomebrewPackageRef(token: $0, kind: kind) }
        } catch let error as HomebrewServiceError {
            if case .commandFailed(_, _, let message) = error,
               isNoSearchResults(message) { return [] }
            throw error
        }
    }

    /// Full metadata for a single package (used by search results + adopt matching).
    static func info(_ ref: HomebrewPackageRef) throws -> HomebrewPackage? {
        var args = ["info", "--json=v2"]
        if ref.isCask { args.append("--cask") }
        args.append(ref.token)
        let out = try run(args)
        let info = try decode(BrewInfoV2.self, out.stdout, arguments: args)
        if ref.isCask, let cask = info.casks.first { return HomebrewPackage(cask: cask) }
        if !ref.isCask, let formula = info.formulae.first { return HomebrewPackage(formula: formula) }
        return nil
    }

    // MARK: - Dependencies

    /// Indented dependency tree (`brew deps --tree`) for a formula's detail pane.
    static func dependencyTree(token: String) throws -> String {
        try run(["deps", "--tree", "--installed", token]).stdout
    }

    /// Installed formulae that still depend on `token` ("required by"), so the UI can
    /// warn before an uninstall that would break something.
    static func usedBy(token: String) throws -> [String] {
        parseNames(try run(["uses", "--installed", "--recursive", token]).stdout)
    }

    // MARK: - Maintenance previews (dry runs)

    /// Human-readable preview of what `brew cleanup` would remove + the reclaimable
    /// size line, taken from `brew cleanup --dry-run`.
    static func cleanupPreview() throws -> String {
        let out = try run(HomebrewActions.cleanupArgs(dryRun: true))
        let text = (out.stdout + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Nothing to clean up." : text
    }

    /// Unused dependencies `brew autoremove` would remove (names only).
    static func autoremovePreview() throws -> [String] {
        let out = try run(["autoremove", "--dry-run"])
        // Output looks like: "Would remove: foo bar baz" or a bullet list — pull the
        // recognizable formula tokens out of either shape.
        let names = parseNames(out.stdout + "\n" + out.stderr)
            .flatMap { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty && $0 != "Would" && $0 != "remove:" && !$0.hasSuffix(":") }
        return Array(Set(names)).sorted()
    }

    /// On-disk size of an installed package's Cellar/Caskroom directory, formatted
    /// (e.g. "14.5 MB"), or nil when it can't be determined.
    static func installedSize(_ pkg: HomebrewPackage) -> String? {
        guard let prefix = HomebrewEnvironment.prefix else { return nil }
        let dir = pkg.isCask ? "\(prefix)/Caskroom/\(pkg.token)" : "\(prefix)/Cellar/\(pkg.token)"
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let bytes = FileSize.size(of: URL(fileURLWithPath: dir))
        return bytes > 0 ? FileSize.string(bytes) : nil
    }

    // MARK: - Helpers

    static func checked(_ output: CommandRunner.Output, arguments: [String]) throws -> CommandRunner.Output {
        guard output.ok else {
            let message = (output.stderr.isEmpty ? output.stdout : output.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HomebrewServiceError.commandFailed(arguments: arguments, status: output.status, message: message)
        }
        return output
    }

    static func isNoSearchResults(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("No formulae or casks found")
    }

    static func parseTaps(_ string: String, arguments: [String] = ["tap-info", "--installed", "--json"]) throws -> [TapInfo] {
        let list = try decode([TapInfo].self, string, arguments: arguments)
        return list.filter(\.installed)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func run(_ arguments: [String]) throws -> CommandRunner.Output {
        guard let brew = HomebrewEnvironment.brewPath else { throw HomebrewServiceError.notInstalled }
        let output = CommandRunner.run(brew, arguments, environment: HomebrewEnvironment.environment())
        return try checked(output, arguments: arguments)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ string: String, arguments: [String]) throws -> T {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw HomebrewServiceError.invalidResponse(arguments: arguments)
        }
        return value
    }

    /// One token per non-empty line, dropping `brew`'s `==> …` section headers.
    private static func parseNames(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
    }
}
