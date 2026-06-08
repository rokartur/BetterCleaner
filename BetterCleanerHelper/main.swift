import Foundation
import Security

// BetterCleanerHelper — privileged LaunchDaemon (runs as root via launchd).
// Vends an XPC mach service the app uses to perform privileged uninstall steps
// (launchctl bootout system/…, mv system files to Trash, pkgutil --forget) in a
// single elevation. Every connection's code signature is verified first, so only
// the genuine, same-team BetterCleaner app can drive it.
//
// NOTE: this file is NOT compiled until the helper target is created — see
// README.md. It shares PrivilegedHelperProtocol.swift with the app target.

let machServiceName = "com.rokartur.BetterCleaner.Helper"

/// Code-signing requirement the connecting app must satisfy. Pinned to the app's
/// bundle ids and Apple Developer Team ID (N529W98U62). Keep in sync with the
/// app's signing if either changes.
let clientRequirement = """
anchor apple generic \
and (identifier "com.rokartur.BetterCleaner" or identifier "com.rokartur.BetterCleaner.debug") \
and certificate leaf[subject.OU] = "N529W98U62"
"""

final class HelperService: NSObject, PrivilegedHelperProtocol {
    func ping(withReply reply: @escaping (String) -> Void) {
        reply("BetterCleanerHelper 1.0")
    }

    func runShell(_ script: String, withReply reply: @escaping (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                reply(true, "")
            } else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                reply(false, String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)")
            }
        } catch {
            reply(false, error.localizedDescription)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard ClientVerifier.isValid(conn) else {
            NSLog("BetterCleanerHelper: rejected unverified client")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        conn.exportedObject = HelperService()
        conn.resume()
        return true
    }
}

/// Verifies a connecting client against `clientRequirement` using its audit token
/// (identity-based, not the racy PID path).
enum ClientVerifier {
    static func isValid(_ conn: NSXPCConnection) -> Bool {
        guard var token = auditToken(of: conn) else { return false }
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// `NSXPCConnection.auditToken` is SPI; read it via KVC. Returns nil if absent.
    private static func auditToken(of conn: NSXPCConnection) -> audit_token_t? {
        guard let value = conn.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token)
        return token
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
