import Foundation

/// Runs a privileged "move to Trash" for system-owned files via one admin
/// password prompt (Authorization Services through `osascript "do shell script
/// … with administrator privileges"`). Files are moved into the user's Trash so
/// the operation stays recoverable.
enum PrivilegedRunner {
    enum RunError: Error {
        case cancelled
        case failed(String)
    }

    /// Run an arbitrary shell command as administrator (one password prompt).
    /// Callers must build the command from trusted/quoted input.
    static func runAdminCommand(_ command: String) throws {
        try runAdmin(shell: command)
    }

    /// Quote a single argument for safe inclusion in an admin shell command.
    static func quote(_ s: String) -> String { shellQuote(s) }

    /// Move `urls` into the Trash folder `container` in one admin elevation.
    static func moveToTrash(_ urls: [URL], container: String) throws {
        let commands = moveCommands(container: container, pairs: urls.map { ($0.path, defaultDest(in: container, for: $0)) })
        guard !commands.isEmpty else { return }
        try runAdmin(shell: commands.joined(separator: " ; "))
    }

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
    /// never a symlink that could point at one).
    private static func isSafeToMove(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if FileMatcher.isProtected(url: url) { return false }
        if FileMatcher.isProtected(url: url.resolvingSymlinksInPath()) { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
    }

    private static func defaultDest(in container: String, for url: URL) -> String {
        (container as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func runAdmin(shell: String) throws {
        let source = "do shell script \(appleScriptString(shell)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8) ?? ""
        // -128 = user cancelled the authentication dialog.
        if message.contains("-128") || message.lowercased().contains("cancel") {
            throw RunError.cancelled
        }
        throw RunError.failed(message)
    }

    /// Single-quote a string for `/bin/sh`.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Produce a double-quoted AppleScript string literal.
    private static func appleScriptString(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + out + "\""
    }
}
