import Foundation

/// Safe wrapper around `Process` for invoking CLI tools (brew, pkgutil,
/// launchctl). Argument arrays only — no shell, so no injection. stdout/stderr
/// are drained concurrently to avoid pipe-buffer deadlock. Non-isolated; call
/// off the main thread.
enum CommandRunner {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Outside the 0-255 range a process can exit with, so `ok` is false and the
    /// status cannot be confused with the tool's own.
    static let cancelledStatus: Int32 = -999

    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        isCancelled: (() -> Bool)? = nil
    ) -> Output {
        guard isCancelled?() != true else {
            return Output(status: cancelledStatus, stdout: "", stderr: "cancelled")
        }
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Output(status: -1, stdout: "", stderr: "not executable: \(launchPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "CommandRunner.io", attributes: .concurrent)
        group.enter()
        queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        // Polling only for callers that can cancel; everyone else blocks, so a
        // long `brew` command does not wake this thread 50 times a second.
        var didCancel = false
        if let isCancelled {
            while process.isRunning {
                if isCancelled() {
                    didCancel = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        process.waitUntilExit()
        group.wait()

        return Output(
            status: didCancel ? cancelledStatus : process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// First existing executable among candidate absolute paths.
    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
