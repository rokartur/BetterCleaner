import Foundation

/// Pure argument builders for every Homebrew mutation, plus a blocking convenience
/// runner for the quick ones (service control, tap/untap). The builders are the
/// unit-tested core — keeping the brew command spelling in one place means the UI
/// never hand-assembles argument arrays.
///
/// Long mutations (install/upgrade/uninstall/cleanup/bundle) are driven by the UI
/// through `HomebrewRunner` using these same builders, so their live logs stream.
enum HomebrewActions {
    enum ServiceAction: String {
        case start, stop, restart
    }

    // MARK: - Package mutations

    /// `brew uninstall [--cask] [--zap] <token>`. `zap` (cask-only) also removes every
    /// file the cask ever created — the "complete uninstall" BetterCleaner is about.
    static func uninstallArgs(_ pkg: HomebrewPackage, zap: Bool) -> [String] {
        var args = ["uninstall"]
        if pkg.isCask {
            args.append("--cask")
            if zap { args.append("--zap") }
        }
        args.append(pkg.token)
        return args
    }

    /// `brew upgrade [--cask] <token>`.
    static func upgradeArgs(_ pkg: HomebrewPackage) -> [String] {
        var args = ["upgrade"]
        if pkg.isCask { args.append("--cask") }
        args.append(pkg.token)
        return args
    }

    /// `brew upgrade [--greedy]` — upgrade everything; `--greedy` also bumps casks
    /// that auto-update.
    static func upgradeAllArgs(greedy: Bool) -> [String] {
        greedy ? ["upgrade", "--greedy"] : ["upgrade"]
    }

    /// `brew install [--cask] <token>`.
    static func installArgs(token: String, isCask: Bool) -> [String] {
        var args = ["install"]
        if isCask { args.append("--cask") }
        args.append(token)
        return args
    }

    /// `brew install --cask --adopt <tokens…>` — take over manually-installed apps,
    /// reusing the existing bundles instead of re-downloading.
    static func adoptArgs(tokens: [String]) -> [String] {
        ["install", "--cask", "--adopt"] + tokens
    }

    // MARK: - Services

    static func serviceArgs(_ action: ServiceAction, name: String) -> [String] {
        ["services", action.rawValue, name]
    }

    // MARK: - Taps

    static func tapArgs(_ name: String) -> [String] { ["tap", name] }
    static func untapArgs(_ name: String) -> [String] { ["untap", name] }

    // MARK: - Maintenance

    static func updateArgs() -> [String] { ["update"] }

    /// `brew cleanup` (real run scrubs the download cache too).
    static func cleanupArgs() -> [String] { ["cleanup", "-s"] }

    static func autoremoveArgs() -> [String] { ["autoremove"] }

    static func bundleDumpArgs(file: String) -> [String] {
        ["bundle", "dump", "--describe", "--force", "--file", file]
    }

    static func bundleInstallArgs(file: String) -> [String] {
        ["bundle", "install", "--file", file]
    }

    // MARK: - Quick blocking runner (fast ops only)

    /// Run a quick brew command and wait. For service control + tap/untap, which
    /// finish in well under a second and have no useful streaming output. Long
    /// operations must go through `HomebrewRunner` instead. Call off the main thread.
    @discardableResult
    static func runQuiet(_ arguments: [String]) -> CommandRunner.Output {
        guard let brew = HomebrewEnvironment.brewPath else {
            return CommandRunner.Output(status: -1, stdout: "", stderr: "Homebrew is not installed.")
        }
        return CommandRunner.run(brew, arguments, environment: HomebrewEnvironment.environment())
    }
}
