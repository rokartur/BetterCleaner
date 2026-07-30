import Foundation

/// One Homebrew mutation with required work followed by cleanup that must run even
/// when a required command fails or the user cancels it.
struct HomebrewCommandPlan: Equatable {
    enum Step: Equatable {
        case required([String])
        case finally([String])

        var arguments: [String] {
            switch self {
            case .required(let arguments), .finally(let arguments): arguments
            }
        }

        var isFinalizer: Bool {
            if case .finally = self { return true }
            return false
        }
    }

    let steps: [Step]

    init(steps: [Step]) { self.steps = steps }
    init(arguments: [String]) { steps = [.required(arguments)] }
}

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
        uninstallArgs(pkg.reference, zap: zap)
    }

    static func uninstallArgs(_ pkg: HomebrewPackageRef, zap: Bool) -> [String] {
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
        args.append(pkg.commandToken)
        return args
    }

    /// Pinned packages must be temporarily unpinned, then re-pinned even if the
    /// upgrade fails or is cancelled.
    static func upgradePlan(_ pkg: HomebrewPackage) -> HomebrewCommandPlan {
        guard pkg.isPinned else {
            return HomebrewCommandPlan(arguments: upgradeArgs(pkg))
        }
        return HomebrewCommandPlan(steps: [
            .required(pinArgs(pkg, pin: false)),
            .required(upgradeArgs(pkg)),
            .finally(pinArgs(pkg, pin: true)),
        ])
    }

    /// `brew install [--cask] <token>`.
    static func installArgs(_ package: HomebrewPackageRef) -> [String] {
        var args = ["install"]
        if package.isCask { args.append("--cask") }
        args.append(package.token)
        return args
    }

    /// `brew install --cask --adopt <tokens…>` — take over manually-installed apps,
    /// reusing the existing bundles instead of re-downloading.
    static func adoptArgs(tokens: [String]) -> [String] {
        ["install", "--cask", "--adopt"] + tokens
    }

    /// `brew pin|unpin --formula|--cask <name>`.
    static func pinArgs(_ pkg: HomebrewPackage) -> [String] {
        pinArgs(pkg, pin: !pkg.isPinned)
    }

    private static func pinArgs(_ pkg: HomebrewPackage, pin: Bool) -> [String] {
        [pin ? "pin" : "unpin", pkg.isCask ? "--cask" : "--formula", pkg.commandToken]
    }

    // MARK: - Services

    static func serviceArgs(_ action: ServiceAction, name: String) -> [String] {
        ["services", action.rawValue, name]
    }

    // MARK: - Taps

    static func validTapName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains) && !part.hasPrefix("-")
        }) else { return nil }
        return name
    }

    static func tapArgs(_ name: String) -> [String] { ["tap", name] }
    static func untapArgs(_ name: String) -> [String] { ["untap", name] }

    // MARK: - Maintenance

    static func updateArgs() -> [String] { ["update"] }

    /// Preview and execution share the same scrub scope; dry-run only adds one flag.
    static func cleanupArgs(dryRun: Bool = false) -> [String] {
        ["cleanup", "-s"] + (dryRun ? ["--dry-run"] : [])
    }

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
