import Foundation

/// Single entry point for running a batch of privileged shell commands in ONE
/// elevation via `osascript "with administrator privileges"` (`PrivilegedRunner`).
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

        do {
            try PrivilegedRunner.runAdminCommand(script)
        } catch PrivilegedRunner.RunError.cancelled {
            throw ExecError.cancelled
        } catch {
            throw ExecError.failed("\(error)")
        }
    }
}
