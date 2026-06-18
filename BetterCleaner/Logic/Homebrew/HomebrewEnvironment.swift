import Foundation

/// Locates the `brew` executable and builds a clean, fast, private environment for
/// invoking it. Apple-Silicon (`/opt/homebrew`) is preferred, then Intel
/// (`/usr/local`).
///
/// `brew` is ALWAYS run as the logged-in user — never through `PrivilegedRunner` /
/// `sudo`. Homebrew refuses to run as root and elevates on its own (via its own
/// prompt) when a cask payload actually needs administrator rights.
enum HomebrewEnvironment {
    /// Candidate absolute paths to the `brew` binary, most-likely first.
    private static let candidates = [
        "/opt/homebrew/bin/brew",   // Apple Silicon
        "/usr/local/bin/brew",      // Intel
    ]

    /// Resolved path to `brew`, or `nil` when Homebrew isn't installed. Cached for
    /// the process lifetime — the prefix doesn't move while the app runs.
    static let brewPath: String? = CommandRunner.firstExecutable(candidates)

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

    /// Environment for every brew invocation: a predictable `PATH` plus flags that
    /// keep output clean (no colour), fast (no auto-update), quiet (no hints) and
    /// private (no analytics — matching the app's no-telemetry stance).
    static func environment() -> [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
        ]
        // Preserve the user's locale so brew's output encoding stays predictable.
        if let lang = ProcessInfo.processInfo.environment["LANG"] { env["LANG"] = lang }
        return env
    }
}
