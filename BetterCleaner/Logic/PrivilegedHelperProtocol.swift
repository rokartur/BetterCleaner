import Foundation

/// XPC contract between the app and the `BetterCleanerHelper` privileged daemon.
///
/// Shared by both targets: this file is in the app target and must also be added
/// to the helper target's membership when that target is created
/// (`BetterCleanerHelper/README.md`). The helper runs as root via launchd and
/// executes the shell batch the app composes (`PrivilegedExecutor`); it verifies
/// the caller's code signature before accepting a connection.
@objc public protocol PrivilegedHelperProtocol {
    /// Run a privileged shell batch as root. `reply` carries success + a message
    /// (stderr / error on failure).
    func runShell(_ script: String, withReply reply: @escaping (Bool, String) -> Void)

    /// Liveness / version probe.
    func ping(withReply reply: @escaping (String) -> Void)
}
