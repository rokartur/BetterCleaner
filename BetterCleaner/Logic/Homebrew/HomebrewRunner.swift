import Foundation

/// Streaming `brew` runner for long-running mutations (install / upgrade / uninstall
/// / cleanup / bundle). Unlike `CommandRunner.run`, which blocks until the process
/// exits, this delivers merged stdout+stderr **line by line** to `onLine` so the UI
/// can show a live log, and supports cancellation via `cancel()`.
///
/// Like every brew call, the process runs as the logged-in user (never sudo).
/// One runner drives one plan at a time. Required steps stop at the first failure;
/// finalizers always run and ignore cancellation so state restoration can finish.
final class HomebrewRunner {
    private let lock = NSLock()
    private let executablePath: String?
    private let environment: [String: String]
    private var process: Process?
    private var processIsFinalizer = false
    private var cancelled = false

    init(executablePath: String? = HomebrewEnvironment.brewPath,
         environment: [String: String] = HomebrewEnvironment.environment()) {
        self.executablePath = executablePath
        self.environment = environment
    }

    /// Run `brew <arguments>`. `onLine` and `completion` are always delivered on the
    /// main queue. `completion(true)` means the process exited 0 and wasn't cancelled.
    func run(_ arguments: [String],
             onLine: @escaping (String) -> Void,
             completion: @escaping (Bool) -> Void) {
        run(HomebrewCommandPlan(arguments: arguments), onLine: onLine, completion: completion)
    }

    func run(_ plan: HomebrewCommandPlan,
             onLine: @escaping (String) -> Void,
             completion: @escaping (Bool) -> Void) {
        guard executablePath != nil else {
            DispatchQueue.main.async {
                onLine("Homebrew is not installed.")
                completion(false)
            }
            return
        }

        lock.lock()
        cancelled = false
        process = nil
        processIsFinalizer = false
        lock.unlock()

        let required = plan.steps.filter { !$0.isFinalizer }
        let finalizers = plan.steps.filter(\.isFinalizer)

        func finish(_ success: Bool) {
            DispatchQueue.main.async { completion(success) }
        }

        func runFinalizer(_ index: Int, requiredSucceeded: Bool, finalizersSucceeded: Bool) {
            guard index < finalizers.count else {
                finish(requiredSucceeded && finalizersSucceeded && !self.isCancelled)
                return
            }
            self.runProcess(finalizers[index].arguments, isFinalizer: true, onLine: onLine) { succeeded in
                runFinalizer(index + 1,
                             requiredSucceeded: requiredSucceeded,
                             finalizersSucceeded: finalizersSucceeded && succeeded)
            }
        }

        func runRequired(_ index: Int) {
            guard !self.isCancelled else {
                runFinalizer(0, requiredSucceeded: false, finalizersSucceeded: true)
                return
            }
            guard index < required.count else {
                runFinalizer(0, requiredSucceeded: true, finalizersSucceeded: true)
                return
            }
            self.runProcess(required[index].arguments, isFinalizer: false, onLine: onLine) { succeeded in
                if succeeded && !self.isCancelled {
                    runRequired(index + 1)
                } else {
                    runFinalizer(0, requiredSucceeded: false, finalizersSucceeded: true)
                }
            }
        }

        runRequired(0)
    }

    private func runProcess(_ arguments: [String], isFinalizer: Bool,
                            onLine: @escaping (String) -> Void,
                            completion: @escaping (Bool) -> Void) {
        guard let executablePath else { completion(false); return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

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
            self?.clearProcess(proc)
            completion(proc.terminationStatus == 0)
        }

        lock.lock()
        self.process = process
        processIsFinalizer = isFinalizer
        lock.unlock()

        do {
            try process.run()
            if isCancelled && !isFinalizer && process.isRunning { process.terminate() }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            clearProcess(process)
            DispatchQueue.main.async {
                onLine("Failed to launch brew: \(error.localizedDescription)")
            }
            completion(false)
        }
    }

    private func clearProcess(_ finished: Process) {
        lock.lock()
        if process === finished {
            process = nil
            processIsFinalizer = false
        }
        lock.unlock()
    }

    /// Terminate the running process (SIGTERM) and mark the run cancelled.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = processIsFinalizer ? nil : process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
