import Foundation

/// Provenance for trashed items: tags each file with which app it belonged to
/// and the moment it was removed (extended attributes that travel into the
/// Trash), and appends to a rolling JSON history the app can surface later.
///
/// Read a trashed item's origin from the shell with:
///   `xattr -p com.rokartur.bettercleaner.origin <file>`
enum TrashMetadata {
    static let originAttr = "com.rokartur.bettercleaner.origin"
    static let dateAttr = "com.rokartur.bettercleaner.removedAt"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Tag a file BEFORE trashing it (on its original path — extended attributes
    /// travel with the move into the Trash). Best-effort; failures are ignored
    /// (e.g. root-owned files moved via the privileged helper).
    static func tag(_ url: URL, origin: String, at date: Date) {
        setXattr(originAttr, origin, on: url)
        setXattr(dateAttr, iso.string(from: date), on: url)
    }

    private static func setXattr(_ name: String, _ value: String, on url: URL) {
        let data = Data(value.utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = data.withUnsafeBytes { buffer in
                setxattr(path, name, buffer.baseAddress, data.count, 0, 0)
            }
        }
    }
}

/// Append-only record of every trash operation: which app/context the files came
/// from, when, how many, and how big.
enum TrashHistory {
    /// Per-file provenance for a removal, enough to offer a Restore.
    /// `trashPath` is where the file landed in the Trash (nil when unknown or not
    /// applicable); `recoverable` is false for actions that don't go to the Trash
    /// (CLI symlinks removed with `rm -f`, `pkgutil --forget`) or that were
    /// overwritten by a later same-named move.
    struct FileRecord: Codable, Hashable {
        let originalPath: String
        var trashPath: String?
        let domain: String // "user" | "system"
        var recoverable: Bool

        init(originalPath: String, trashPath: String?, domain: String, recoverable: Bool) {
            self.originalPath = originalPath
            self.trashPath = trashPath
            self.domain = domain
            self.recoverable = recoverable
        }
    }

    struct Entry: Codable, Identifiable {
        let date: Date
        let origin: String
        let count: Int
        let bytes: Int64
        let paths: [String]
        /// Per-file records (added later). Optional so legacy history decodes; a
        /// nil `files` entry is shown but offers no Restore.
        var files: [FileRecord]?
        var id: String { "\(date.timeIntervalSince1970)-\(origin)" }

        init(date: Date, origin: String, count: Int, bytes: Int64, paths: [String], files: [FileRecord]? = nil) {
            self.date = date
            self.origin = origin
            self.count = count
            self.bytes = bytes
            self.paths = paths
            self.files = files
        }
    }

    private static let maxEntries = 1000
    private static let lock = NSLock()

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("BetterCleaner", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trash-history.json")
    }

    /// Record a move-to-Trash operation (file URLs). Legacy form with no per-file
    /// restore data — prefer `record(origin:files:bytes:at:)`.
    static func record(origin: String, urls: [URL], bytes: Int64, at date: Date) {
        recordRemoval(origin: origin, items: urls.map(\.path), bytes: bytes, at: date)
    }

    /// Record a removal with per-file provenance so the Delete History window can
    /// offer a Restore.
    static func record(origin: String, files: [FileRecord], bytes: Int64, at date: Date) {
        guard !files.isEmpty, let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all.append(Entry(date: date, origin: origin, count: files.count, bytes: bytes, paths: files.map(\.originalPath), files: files))
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        persistLocked(all, to: fileURL)
    }

    /// Record any removal/cleanup action — including ones that don't go to the
    /// Trash (Homebrew uninstall, package-receipt forget) — by a list of human
    /// identifiers (package names, receipt ids, paths).
    static func recordRemoval(origin: String, items: [String], bytes: Int64, at date: Date) {
        guard !items.isEmpty, let fileURL else { return }
        lock.lock(); defer { lock.unlock() }

        var all = loadLocked()
        all.append(Entry(date: date, origin: origin, count: items.count, bytes: bytes, paths: items))
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        persistLocked(all, to: fileURL)
    }

    private static func persistLocked(_ all: [Entry], to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(all) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().reversed()
    }

    /// Forget a single recorded batch (by `Entry.id`). Only drops the log row —
    /// files already in the Trash are untouched. Returns whether anything changed.
    @discardableResult
    static func remove(id: String) -> Bool {
        guard let fileURL else { return false }
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return false }
        persistLocked(all, to: fileURL)
        return true
    }

    /// Erase the whole deletion history. Files in the Trash are unaffected and can
    /// still be recovered from the Trash itself.
    static func clear() {
        guard let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func loadLocked() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
