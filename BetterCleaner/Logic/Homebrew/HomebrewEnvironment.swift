import Foundation

/// Locates the `brew` executable and builds the environment used for every invocation.
///
/// `brew` is ALWAYS launched as the logged-in user — never through
/// `PrivilegedRunner` / `sudo`; Homebrew refuses to run as root. When a cask
/// payload itself needs administrator rights, brew's own internal `sudo` has no
/// terminal to prompt on, so `SUDO_ASKPASS` points at the bundled
/// `homebrew-sudo-askpass` script: an osascript dialog with hidden input that
/// asks the user for their password and hands it to `sudo`. That script is the
/// app's only privilege-escalation path for brew; the password is never seen or
/// stored by BetterCleaner itself. Pass `includeAskpass: false` for read-only
/// invocations that must never elevate.
enum HomebrewEnvironment {
    /// Candidate absolute paths to the `brew` binary, most-likely first.
    private static let candidates = [
        "/opt/homebrew/bin/brew",   // Apple Silicon
        "/usr/local/bin/brew",      // Intel
    ]

    /// Resolved on every access so installing Homebrew while BetterCleaner is open
    /// does not require an app restart.
    static var brewPath: String? {
        resolveBrewPath(
            environment: ProcessInfo.processInfo.environment,
            standardCandidates: candidates,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    static var isInstalled: Bool { brewPath != nil }

    /// The Homebrew prefix (`/opt/homebrew` or `/usr/local`) derived from the
    /// resolved binary path, or `nil` when brew isn't found.
    static var prefix: String? {
        guard let brewPath else { return nil }
        // /opt/homebrew/bin/brew -> /opt/homebrew
        return URL(fileURLWithPath: brewPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    /// Keep the user's proxy, SSH agent, locale, temporary directory and Homebrew
    /// preferences. Only the flags BetterCleaner owns are overridden.
    static func environment(includeAskpass: Bool = true) -> [String: String] {
        environment(
            base: ProcessInfo.processInfo.environment,
            brewPath: brewPath,
            askpassPath: includeAskpass ? askpassPath : nil
        )
    }

    static func resolveBrewPath(environment: [String: String],
                                standardCandidates: [String],
                                isExecutable: (String) -> Bool) -> String? {
        var paths: [String] = []
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            paths.append((prefix as NSString).appendingPathComponent("bin/brew"))
        }
        paths += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { (String($0) as NSString).appendingPathComponent("brew") }
        paths += standardCandidates
        return paths.first(where: isExecutable)
    }

    static func environment(base: [String: String], brewPath: String?, askpassPath: String?) -> [String: String] {
        var env = base
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }

        var pathEntries: [String] = []
        if let brewPath {
            let bin = URL(fileURLWithPath: brewPath).deletingLastPathComponent()
            pathEntries += [bin.path, bin.deletingLastPathComponent().appendingPathComponent("sbin").path]
        }
        pathEntries += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        pathEntries += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = pathEntries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")

        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] = "1"
        if let askpassPath { env["SUDO_ASKPASS"] = askpassPath }
        else { env.removeValue(forKey: "SUDO_ASKPASS") }
        return env
    }

    static var askpassPath: String? {
        guard let path = Bundle.main.path(forResource: "homebrew-sudo-askpass", ofType: nil),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
