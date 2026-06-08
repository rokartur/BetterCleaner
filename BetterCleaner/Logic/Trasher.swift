import AppKit

/// Moves selected items to the Trash. User-domain files go through
/// `FileManager.trashItem`; anything that fails with a permission error is
/// retried through `PrivilegedRunner` (one admin prompt for the batch).
enum Trasher {
    struct Outcome {
        var trashed: [URL]
        var failed: [URL]
        var cancelled: Bool
    }

    /// `origin` labels where the files came from (an app name, "Languages",
    /// "Orphaned Files", …). It is written to each item's extended attributes and
    /// to the trash history, so the user can later see which app — and at what
    /// time — something was removed.
    @discardableResult
    static func trash(_ items: [FileItem], origin: String? = nil) -> Outcome {
        let fm = FileManager.default
        let now = Date()
        let label = origin ?? "BetterCleaner"
        let sizeByPath = Dictionary(items.map { ($0.url.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        // Group everything from this removal into one "<origin> — <date>" folder in
        // the Trash instead of scattering loose entries at the Trash root.
        let box = TrashBox.make(origin: label, at: now) ?? TrashBox.trashRoot
        var usedNames = Set<String>()
        var trashed: [URL] = []
        var privilegedPairs: [(src: String, dest: String)] = []
        var privilegedURLs: [URL] = []
        // Per-file restore records, keyed by original path, recorded into history.
        var records: [String: TrashHistory.FileRecord] = [:]

        for item in items {
            // Re-check the protection denylist at the moment of deletion (not just
            // at scan time) to close the scan→trash TOCTOU window, on both the
            // literal and symlink-resolved path. Never trash a symlink (it could
            // point at a protected target).
            if FileMatcher.isProtected(url: item.url) { continue }
            if FileMatcher.isProtected(url: item.url.resolvingSymlinksInPath()) { continue }
            let symlink = (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
            if symlink == true { continue }
            // Stamp provenance before the move so the xattrs travel into the Trash.
            TrashMetadata.tag(item.url, origin: label, at: now)
            let dest = box.appendingPathComponent(TrashBox.uniqueName(in: box, for: item.url.lastPathComponent, used: &usedNames))
            do {
                try fm.moveItem(at: item.url, to: dest)
                trashed.append(item.url)
                records[item.url.path] = TrashHistory.FileRecord(
                    originalPath: item.url.path,
                    trashPath: dest.path,
                    domain: item.domain == .system ? "system" : "user",
                    recoverable: true)
            } catch {
                // Permission-denied (e.g. root-owned): fold into one admin batch.
                privilegedPairs.append((item.url.path, dest.path))
                privilegedURLs.append(item.url)
                records[item.url.path] = TrashHistory.FileRecord(
                    originalPath: item.url.path,
                    trashPath: dest.path,
                    domain: "system",
                    recoverable: true)
            }
        }

        func finish(_ outcome: Outcome) -> Outcome {
            let bytes = outcome.trashed.reduce(Int64(0)) { $0 + (sizeByPath[$1.path] ?? 0) }
            let files = outcome.trashed.compactMap { records[$0.path] }
            TrashHistory.record(origin: label, files: files, bytes: bytes, at: now)
            return outcome
        }

        guard !privilegedPairs.isEmpty else {
            return finish(Outcome(trashed: trashed, failed: [], cancelled: false))
        }

        let commands = PrivilegedRunner.moveCommands(container: box.path, pairs: privilegedPairs)
        do {
            try PrivilegedRunner.runAdminCommand(commands.joined(separator: " ; "))
            trashed.append(contentsOf: privilegedURLs)
            return finish(Outcome(trashed: trashed, failed: [], cancelled: false))
        } catch PrivilegedRunner.RunError.cancelled {
            return finish(Outcome(trashed: trashed, failed: privilegedURLs, cancelled: true))
        } catch {
            return finish(Outcome(trashed: trashed, failed: privilegedURLs, cancelled: false))
        }
    }
}
