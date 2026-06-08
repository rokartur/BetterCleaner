import Foundation
import ServiceManagement

/// App-side client for the SMAppService privileged helper (`BetterCleanerHelper`).
///
/// The helper is a LaunchDaemon registered via `SMAppService.daemon(plistName:)`
/// that runs privileged shell batches over XPC, verifying the caller's code
/// signature. It exists only when the helper target is built into the app bundle
/// and approved by the user in System Settings → Login Items.
///
/// Until that target is wired (see `BetterCleanerHelper/README.md`), the daemon's
/// status is `.notRegistered`, so `shared` is nil and `PrivilegedExecutor`
/// transparently falls back to osascript — every privileged feature still works
/// on unsigned/dev builds without a helper.
final class PrivilegedHelperClient {
    enum HelperError: Error {
        case cancelled
        case notReady
        case failed(String)
    }

    /// The shared client, or nil when no embedded/approved helper is available.
    static let shared: PrivilegedHelperClient? = makeIfAvailable()

    /// Name of the helper's bundled launchd plist (Contents/Library/LaunchDaemons).
    static let plistName = "com.rokartur.BetterCleaner.Helper.plist"
    /// Mach service the helper vends and the app connects to.
    static let machServiceName = "com.rokartur.BetterCleaner.Helper"

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    private init() {}

    /// True once the daemon is registered + enabled (approved). Re-checked live
    /// because the user can approve/revoke in System Settings at any time.
    var isReady: Bool {
        SMAppService.daemon(plistName: Self.plistName).status == .enabled
    }

    /// Run a privileged shell batch through the helper, blocking until it replies.
    /// Throws `.notReady` (→ caller falls back to osascript) or `.failed`.
    func runShell(_ script: String) throws {
        guard isReady else { throw HelperError.notReady }
        let conn = currentConnection()

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? PrivilegedHelperProtocol else {
            throw HelperError.notReady
        }

        var thrown: Error?
        let semaphore = DispatchSemaphore(value: 0)
        proxy.runShell(script) { ok, message in
            if !ok { thrown = HelperError.failed(message) }
            semaphore.signal()
        }
        // The XPC call can fail to deliver (helper crash); guard with a timeout so
        // the uninstall thread can't hang forever, then fall back.
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            throw HelperError.failed("helper timed out")
        }
        if let thrown { throw thrown }
    }

    /// Register the daemon (installs it; triggers the user-approval flow). Call
    /// from a Settings action once the helper target is embedded — see README.
    static func register() throws {
        try SMAppService.daemon(plistName: plistName).register()
    }

    static func unregister() throws {
        try SMAppService.daemon(plistName: plistName).unregister()
    }

    // MARK: - Connection

    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let conn = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            self?.lock.lock(); self?.connection = nil; self?.lock.unlock()
        }
        conn.interruptionHandler = { [weak self] in
            self?.lock.lock(); self?.connection = nil; self?.lock.unlock()
        }
        conn.resume()
        connection = conn
        return conn
    }

    private static func makeIfAvailable() -> PrivilegedHelperClient? {
        // `.enabled` only for a real, embedded, approved helper. Anything else
        // (the common case until the target is wired) → nil → osascript fallback.
        switch SMAppService.daemon(plistName: plistName).status {
        case .enabled:
            return PrivilegedHelperClient()
        default:
            return nil
        }
    }
}
