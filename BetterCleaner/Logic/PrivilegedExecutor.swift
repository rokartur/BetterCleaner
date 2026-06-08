import Foundation

/// Single entry point for running privileged shell work in ONE elevation.
///
/// Backends, in preference order:
///  1. A signed SMAppService helper (`PrivilegedHelperClient`) — no repeated
///     password prompts, caller code-signature verified. Used when the helper is
///     registered and approved (see `BetterCleanerHelper`).
///  2. `osascript "with administrator privileges"` (`PrivilegedRunner`) — the
///     fallback for unsigned/dev builds or before the helper is approved.
///
/// Callers build each command from quoted, trusted input (`PrivilegedRunner.quote`)
/// and pass them as a batch so the whole uninstall costs at most one prompt.
enum PrivilegedExecutor {
    enum ExecError: Error {
        case cancelled
        case failed(String)
    }

    /// Run a batch of shell commands in one elevation. Commands are joined with
    /// `;` so each runs independently (a failed `launchctl bootout` of an
    /// already-unloaded job does not abort the file moves that follow). Empty
    /// commands are dropped; an all-empty batch is a no-op.
    static func runBatch(_ commands: [String]) throws {
        let cleaned = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let script = cleaned.joined(separator: " ; ")

        if let helper = PrivilegedHelperClient.shared, helper.isReady {
            do {
                try helper.runShell(script)
                return
            } catch PrivilegedHelperClient.HelperError.cancelled {
                throw ExecError.cancelled
            } catch {
                // Helper present but failed mid-call: fall through to osascript so
                // the operation still completes rather than silently dropping.
            }
        }

        do {
            try PrivilegedRunner.runAdminCommand(script)
        } catch PrivilegedRunner.RunError.cancelled {
            throw ExecError.cancelled
        } catch {
            throw ExecError.failed("\(error)")
        }
    }

    /// Whether a signed helper is installed and ready (so the UI can mention that
    /// uninstalls won't prompt). False on unsigned/dev builds.
    static var hasPrivilegedHelper: Bool {
        PrivilegedHelperClient.shared?.isReady ?? false
    }
}
