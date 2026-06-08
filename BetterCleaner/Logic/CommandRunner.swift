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

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], environment: [String: String]? = nil) -> Output {
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
        process.waitUntilExit()
        group.wait()

        return Output(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// First existing executable among candidate absolute paths.
    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
