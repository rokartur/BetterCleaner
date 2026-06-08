import Foundation

/// A named, dated folder inside the user's Trash that a removal's files are
/// grouped into — e.g. `~/.Trash/Spotify — 2026-06-03 at 14.30.05/` — instead of
/// scattering them loose at the Trash root. Recoverable like anything in the
/// Trash; BetterCleaner's Delete History restores from the recorded paths.
enum TrashBox {
    static var trashRoot: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.Trash") }

    /// The folder name for a removal: `<origin> — <date>`, path-safe. Pure.
    static func folderName(origin: String, at date: Date) -> String {
        "\(sanitize(origin)) — \(stamp(date))"
    }

    /// Create a uniquely-named `<origin> — <date>` folder in the Trash and return
    /// it, or nil if it can't be created (caller falls back to the Trash root).
    static func make(origin: String, at date: Date) -> URL? {
        let fm = FileManager.default
        let base = folderName(origin: origin, at: date)
        var name = base
        var n = 2
        while fm.fileExists(atPath: trashRoot.appendingPathComponent(name).path) {
            name = "\(base) (\(n))"
            n += 1
        }
        let box = trashRoot.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: box, withIntermediateDirectories: true)
            return box
        } catch {
            return nil
        }
    }

    /// A non-colliding file name for `name` inside `box`, recording the choice in
    /// `used` so a single batch never targets the same name twice. Pure except for
    /// an on-disk existence check.
    static func uniqueName(in box: URL, for name: String, used: inout Set<String>) -> String {
        let safeName = name.isEmpty ? "item" : name
        var candidate = safeName
        let stem = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var n = 2
        while used.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: box.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func sanitize(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "BetterCleaner" : trimmed
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }
}
