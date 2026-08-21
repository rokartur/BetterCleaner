import Foundation

/// Runs a batch of shell commands under one admin password prompt
/// (Authorization Services through `osascript "do shell script … with
/// administrator privileges"`): file moves, `launchctl bootout`,
/// `pkgutil --forget`, `rm -f`. `moveCommands` is what keeps removals
/// recoverable, by moving into the user's Trash rather than unlinking.
enum PrivilegedRunner {
    /// `LocalizedError` because every caller surfaces these straight to the user
    /// as the reason a file was left behind.
    enum RunError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "the administrator prompt was cancelled"
            case .failed(let message): Self.oneLine(message)
            }
        }

        /// The batch is one `mv` per file joined by `;`, so stderr can be many
        /// lines. Callers put this inside a sentence, so collapse it to one.
        private static func oneLine(_ message: String) -> String {
            let joined = message.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            if joined.isEmpty { return "the command failed without saying why" }
            return joined.count > 200 ? joined.prefix(200) + "…" : joined
        }
    }

    /// Run a batch of shell commands as administrator, in ONE password prompt.
    /// Callers must build each command from trusted/quoted input (`quote`).
    ///
    /// Commands are joined with `;` so each runs independently: a failed
    /// `launchctl bootout` of an already-unloaded job does not abort the file
    /// moves that follow. That also means the exit status only speaks for the
    /// last command — callers who need per-item truth must ask the disk.
    /// Empty commands are dropped; an all-empty batch is a no-op.
    static func runBatch(_ commands: [String]) throws {
        let cleaned = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        try runAdmin(shell: cleaned.joined(separator: " ; "))
    }

    /// Quote a single argument for safe inclusion in an admin shell command.
    static func quote(_ text: String) -> String { shellQuote(text) }

    /// Build the shell commands that move each `src` to its explicit `dest` (both
    /// inside `container`), without running them — so a caller (`Trasher` /
    /// `AppRemover`) can compose them with `launchctl bootout` / `pkgutil --forget`
    /// into one privilege elevation. Returns one `mkdir -p <container>` plus an
    /// independent `mv` per file, so a single vanished/locked file can't abort the
    /// rest of the batch. Applies the protected/symlink validation: an admin `mv`
    /// can never be steered at a protected target.
    static func moveCommands(container: String, pairs: [(src: String, dest: String)]) -> [String] {
        let safe = pairs.filter { isSafeToMove($0.src) }
        guard !safe.isEmpty else { return [] }
        var commands = ["mkdir -p \(shellQuote(container))"]
        for pair in safe {
            commands.append("/bin/mv -f \(shellQuote(pair.src)) \(shellQuote(pair.dest))")
        }
        return commands
    }

    /// Whether an admin `mv` may target this source path (never a protected file,
    /// never a symlink that could point at one). Public so `Trasher` can record
    /// only the files this batch will actually move (not the ones it filters out).
    static func isSafeToMove(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if FileMatcher.isProtected(url: url) { return false }
        if FileMatcher.isProtected(url: url.resolvingSymlinksInPath()) { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
    }

    private static func runAdmin(shell: String) throws {
        let source = "do shell script \(appleScriptString(shell)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        // Nothing reads the script's stdout, and an undrained pipe deadlocks the
        // app once the batch fills its 64 KB buffer — hundreds of `mv`s do.
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        // Drain before waiting, for the same reason.
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let message = String(data: data, encoding: .utf8) ?? ""
        // -128 = user cancelled the authentication dialog. Match osascript's own
        // wording only: file paths reach this text, and one named "cancelled"
        // would otherwise turn a permission failure into a silent "never mind".
        if message.contains("-128") || message.contains("User canceled") {
            throw RunError.cancelled
        }
        throw RunError.failed(message)
    }

    /// Single-quote a string for `/bin/sh`.
    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Produce a double-quoted AppleScript string literal.
    private static func appleScriptString(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + out + "\""
    }
}
