import Foundation

/// Streaming `brew` runner for long-running mutations (install / upgrade / uninstall
/// / cleanup / bundle). Unlike `CommandRunner.run`, which blocks until the process
/// exits, this delivers merged stdout+stderr **line by line** to `onLine` so the UI
/// can show a live log, and supports cancellation via `cancel()`.
///
/// Like every brew call, the process runs as the logged-in user (never sudo).
/// One runner drives one invocation; create a fresh instance per operation.
final class HomebrewRunner {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Run `brew <arguments>`. `onLine` and `completion` are always delivered on the
    /// main queue. `completion(true)` means the process exited 0 and wasn't cancelled.
    func run(_ arguments: [String],
             onLine: @escaping (String) -> Void,
             completion: @escaping (Bool) -> Void) {
        guard let brew = HomebrewEnvironment.brewPath else {
            DispatchQueue.main.async {
                onLine("Homebrew is not installed.")
                completion(false)
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        process.environment = HomebrewEnvironment.environment()

        // Merge stdout + stderr into one pipe so the live log reads in order.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Accumulate partial reads and emit only whole lines. `buffer` is touched
        // solely inside this serialized readability handler, so no extra locking.
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {                       // EOF
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    DispatchQueue.main.async { onLine(line) }
                }
                buffer.removeAll()
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                DispatchQueue.main.async { onLine(line) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0 && !(self?.isCancelled ?? false)
            DispatchQueue.main.async { completion(ok) }
        }

        lock.lock(); self.process = process; lock.unlock()

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                onLine("Failed to launch brew: \(error.localizedDescription)")
                completion(false)
            }
        }
    }

    /// Terminate the running process (SIGTERM) and mark the run cancelled.
    func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
