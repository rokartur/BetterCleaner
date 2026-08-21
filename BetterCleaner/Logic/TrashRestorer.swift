import Foundation

/// Restores files recorded by `TrashHistory` from the Trash back to their
/// original locations. User-domain files move with `FileManager`; system-domain
/// files move in one privileged batch (`PrivilegedRunner.runBatch`).
///
/// Never clobbers a re-created original (`restorable` excludes occupied targets;
/// `FileManager.moveItem` itself refuses to overwrite), and never restores onto a
/// protected path.
enum TrashRestorer {
    struct Result {
        var restored: [String] = []
        var failed: [String] = []
        var cancelled = false
    }

    /// The subset of `files` that can actually be restored right now: marked
    /// recoverable, still present in the Trash, with a free + non-protected
    /// original location.
    static func restorable(_ files: [TrashHistory.FileRecord]) -> [TrashHistory.FileRecord] {
        let fm = FileManager.default
        return files.filter { rec in
            guard rec.recoverable, let trashPath = rec.trashPath else { return false }
            guard fm.fileExists(atPath: trashPath) else { return false }        // emptied from Trash
            guard !fm.fileExists(atPath: rec.originalPath) else { return false } // original re-created
            return !FileMatcher.isProtected(url: URL(fileURLWithPath: rec.originalPath))
        }
    }

    /// Move every restorable file back. Returns which paths were restored, which
    /// failed, and whether the admin prompt for system files was cancelled.
    @discardableResult
    static func restore(_ files: [TrashHistory.FileRecord]) -> Result {
        let fm = FileManager.default
        let candidates = restorable(files)
        var result = Result()

        for rec in candidates where rec.domain != "system" {
            guard let trashPath = rec.trashPath else { continue }
            let dest = URL(fileURLWithPath: rec.originalPath)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trashPath), to: dest)
                result.restored.append(rec.originalPath)
            } catch {
                result.failed.append(rec.originalPath)
            }
        }

        let systemRecords = candidates.filter { $0.domain == "system" }
        let commands = moveBackCommands(for: systemRecords)
        guard !commands.isEmpty else { return result }

        do {
            try PrivilegedRunner.runBatch(commands)
            result.restored.append(contentsOf: systemRecords.map(\.originalPath))
        } catch PrivilegedRunner.RunError.cancelled {
            result.cancelled = true
            result.failed.append(contentsOf: systemRecords.map(\.originalPath))
        } catch {
            result.failed.append(contentsOf: systemRecords.map(\.originalPath))
        }
        return result
    }

    /// Pure: the shell commands that move each system file from its Trash path
    /// back to its original location — `mkdir -p` the parent, then a plain `mv`
    /// (no `-f`). Skips non-recoverable records and protected targets. Unit-tested.
    static func moveBackCommands(for files: [TrashHistory.FileRecord]) -> [String] {
        var commands: [String] = []
        for rec in files {
            guard rec.recoverable, let trashPath = rec.trashPath else { continue }
            let target = URL(fileURLWithPath: rec.originalPath)
            if FileMatcher.isProtected(url: target) { continue }
            let parent = target.deletingLastPathComponent().path
            commands.append("mkdir -p \(PrivilegedRunner.quote(parent))")
            commands.append("/bin/mv \(PrivilegedRunner.quote(trashPath)) \(PrivilegedRunner.quote(rec.originalPath))")
        }
        return commands
    }
}
