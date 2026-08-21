import Foundation

/// A named, dated folder inside the user's Trash that a removal's files are
/// grouped into — e.g. `~/.Trash/Spotify — 2026-06-03 at 14.30.05/` — instead of
/// scattering them loose at the Trash root. Recoverable like anything in the
/// Trash; BetterCleaner's Delete History restores from the recorded paths.
enum TrashBox {
    static var trashRoot: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.Trash") }

    /// Whether `url` lives on the same volume as the user's Trash. A move to
    /// another volume is silently a copy, so a file on an external drive would be
    /// hauled onto the boot disk instead of into that drive's own Trash.
    /// Unknown volumes answer `true`, keeping the ordinary path.
    static func isOnTrashVolume(_ url: URL) -> Bool {
        guard let itemVolume = volumeID(of: url), let trashVolume = volumeID(of: trashRoot) else { return true }
        return itemVolume.isEqual(trashVolume)
    }

    private static func volumeID(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

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
        var suffix = 2
        while fm.fileExists(atPath: trashRoot.appendingPathComponent(name).path) {
            name = "\(base) (\(suffix))"
            suffix += 1
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
        var suffix = 2
        while used.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: box.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func sanitize(_ origin: String) -> String {
        let cleaned = origin.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "BetterCleaner" : trimmed
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
