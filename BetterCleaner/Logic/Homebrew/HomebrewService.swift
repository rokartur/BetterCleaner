import Foundation

/// Read-only Homebrew queries — installed packages, services, taps, search, single-
/// package info, dependency trees, and maintenance previews. Every method shells out
/// to `brew` through `CommandRunner` and parses JSON / text.
///
/// Non-isolated: call off the main thread (mirrors `PackageScanner`). All methods
/// fail soft — they return empty/`nil` when brew is missing or a command errors, so
/// the UI degrades to an empty state instead of throwing.
enum HomebrewService {
    private static var brew: String? { HomebrewEnvironment.brewPath }
    private static var env: [String: String] { HomebrewEnvironment.environment() }

    // MARK: - Installed packages

    /// Installed formulae + casks, unified and sorted by display name.
    static func installedPackages() -> [HomebrewPackage] {
        guard let brew else { return [] }
        let out = CommandRunner.run(brew, ["info", "--json=v2", "--installed"], environment: env)
        guard out.ok, let info = decode(BrewInfoV2.self, out.stdout) else { return [] }
        let packages = info.formulae.map(HomebrewPackage.init(formula:))
            + info.casks.map(HomebrewPackage.init(cask:))
        return packages.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Services

    static func services() -> [ServiceInfo] {
        guard let brew else { return [] }
        let out = CommandRunner.run(brew, ["services", "list", "--json"], environment: env)
        guard out.ok, let list = decode([ServiceInfo].self, out.stdout) else { return [] }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Taps

    static func taps() -> [TapInfo] {
        guard let brew else { return [] }
        let out = CommandRunner.run(brew, ["tap-info", "--installed", "--json"], environment: env)
        guard out.ok, let list = decode([TapInfo].self, out.stdout) else { return [] }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Search & single-package info

    struct SearchHit {
        let token: String
        let isCask: Bool
    }

    /// Names matching `query` across formulae and casks (`brew search`). Returns the
    /// raw tokens; the caller fetches descriptions lazily via `info(token:isCask:)`.
    static func search(_ query: String) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brew, !trimmed.isEmpty else { return [] }
        var hits: [SearchHit] = []
        let formulae = CommandRunner.run(brew, ["search", "--formula", trimmed], environment: env)
        if formulae.ok { hits += parseNames(formulae.stdout).map { SearchHit(token: $0, isCask: false) } }
        let casks = CommandRunner.run(brew, ["search", "--cask", trimmed], environment: env)
        if casks.ok { hits += parseNames(casks.stdout).map { SearchHit(token: $0, isCask: true) } }
        return hits
    }

    /// Full metadata for a single package (used by search results + adopt matching).
    static func info(token: String, isCask: Bool) -> HomebrewPackage? {
        guard let brew else { return nil }
        var args = ["info", "--json=v2"]
        if isCask { args.append("--cask") }
        args.append(token)
        let out = CommandRunner.run(brew, args, environment: env)
        guard out.ok, let info = decode(BrewInfoV2.self, out.stdout) else { return nil }
        if isCask, let cask = info.casks.first { return HomebrewPackage(cask: cask) }
        if let formula = info.formulae.first { return HomebrewPackage(formula: formula) }
        return nil
    }

    // MARK: - Dependencies

    /// Indented dependency tree (`brew deps --tree`) for a formula's detail pane.
    static func dependencyTree(token: String) -> String {
        guard let brew else { return "" }
        let out = CommandRunner.run(brew, ["deps", "--tree", "--installed", token], environment: env)
        return out.ok ? out.stdout : ""
    }

    /// Installed formulae that still depend on `token` ("required by"), so the UI can
    /// warn before an uninstall that would break something.
    static func usedBy(token: String) -> [String] {
        guard let brew else { return [] }
        let out = CommandRunner.run(brew, ["uses", "--installed", "--recursive", token], environment: env)
        guard out.ok else { return [] }
        return parseNames(out.stdout)
    }

    // MARK: - Maintenance previews (dry runs)

    /// Human-readable preview of what `brew cleanup` would remove + the reclaimable
    /// size line, taken from `brew cleanup --dry-run`.
    static func cleanupPreview() -> String {
        guard let brew else { return "" }
        let out = CommandRunner.run(brew, ["cleanup", "--dry-run"], environment: env)
        let text = (out.stdout + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Nothing to clean up." : text
    }

    /// Unused dependencies `brew autoremove` would remove (names only).
    static func autoremovePreview() -> [String] {
        guard let brew else { return [] }
        let out = CommandRunner.run(brew, ["autoremove", "--dry-run"], environment: env)
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

    private static func decode<T: Decodable>(_ type: T.Type, _ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// One token per non-empty line, dropping `brew`'s `==> …` section headers.
    private static func parseNames(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
    }
}
