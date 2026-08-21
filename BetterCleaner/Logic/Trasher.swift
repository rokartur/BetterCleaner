import AppKit

/// Moves selected items to the Trash: into a grouped `<origin> — <date>` folder
/// on the boot volume, into the system Trash of whatever volume they live on
/// otherwise. Only a genuine permission error is retried through
/// `PrivilegedRunner` (one admin prompt for the batch).
enum Trasher {
    struct Outcome {
        var trashed: [URL]
        var failed: [URL]
        /// Items deliberately left where they are — protected paths and symlinks.
        /// Not failures, but the caller must not report them as removed either.
        var skipped: [URL] = []
        var cancelled: Bool
        /// What the file system said about the first failure, so the message can
        /// name a read-only volume instead of guessing at permissions.
        var failureReason: String?

        /// Everything this removal did not finish, or nil when it finished. Skipped
        /// items get their own sentence: they are not failures, but they did not go
        /// anywhere either, and silence about them reads as success. A cancelled
        /// prompt that moved nothing is not a report — the user knows. Skips are
        /// the exception: they were decided before anything asked for a password,
        /// so cancelling does not explain them away.
        func incompleteMessage(verb: String) -> String? {
            var lines: [String] = []
            // Silence is only right when it would be the whole message. Once there
            // is a skip line, the sheet lists the failures too, and a summary that
            // mentions only the skips contradicts the list above it.
            let cancelIsTheWholeStory = cancelled && trashed.isEmpty && skipped.isEmpty
            if !failed.isEmpty && !cancelIsTheWholeStory {
                let fallback = cancelled ? "the administrator prompt was cancelled" : "permission denied or in use"
                let reason = (failureReason ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("\(trashed.count) \(verb), \(failed.count) failed "
                    + "(\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason)).")
            }
            if !skipped.isEmpty {
                let one = skipped.count == 1
                lines.append("\(skipped.count) item\(one ? " was" : "s were") left in place "
                    + "(protected or a link).")
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
        }
    }

    /// Whether an admin prompt could plausibly help. A read-only volume or a full
    /// disk fails exactly the same way for root, so retrying costs the user a
    /// password dialog and changes nothing.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return posix.code == Int(EPERM) || posix.code == Int(EACCES)
        }
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError)
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
        let sizeByPath = Dictionary(items.map { ($0.url.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        // Group everything from this removal into one "<origin> — <date>" folder in
        // the Trash instead of scattering loose entries at the Trash root.
        let box = TrashBox.make(origin: label, at: now) ?? TrashBox.trashRoot
        var usedNames = Set<String>()
        var trashed: [URL] = []
        var failed: [URL] = []
        var skipped: [URL] = []
        var failureReason: String?
        var privilegedPairs: [(src: String, dest: String)] = []
        var privilegedURLs: [URL] = []
        // Per-file restore records, keyed by original path, recorded into history.
        var records: [String: TrashHistory.FileRecord] = [:]

        for item in items {
            // Re-check the protection denylist at the moment of deletion (not just
            // at scan time) to close the scan→trash TOCTOU window, on both the
            // literal and symlink-resolved path. Never trash a symlink (it could
            // point at a protected target).
            if FileMatcher.isProtected(url: item.url) { skipped.append(item.url); continue }
            if FileMatcher.isProtected(url: item.url.resolvingSymlinksInPath()) { skipped.append(item.url); continue }
            let symlink = (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
            if symlink == true { skipped.append(item.url); continue }
            // Stamp provenance before the move so the xattrs travel into the Trash.
            TrashMetadata.tag(item.url, origin: label, at: now)
            // A file on another volume goes into that volume's own Trash: moving it
            // into the boot disk's box would copy every byte across, and an admin
            // retry would only copy it again.
            guard TrashBox.isOnTrashVolume(item.url) else {
                var landed: NSURL?
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: &landed)
                    trashed.append(item.url)
                    // The system usually reports where it put the file; without that
                    // path there is nothing to restore from, so say so.
                    let trashPath = (landed as URL?)?.path
                    records[item.url.path] = TrashHistory.FileRecord(
                        originalPath: item.url.path,
                        trashPath: trashPath,
                        domain: item.domain == .system ? "system" : "user",
                        recoverable: trashPath != nil)
                } catch {
                    failed.append(item.url)
                    failureReason = failureReason ?? error.localizedDescription
                }
                continue
            }
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
                guard isPermissionDenied(error) else {
                    failed.append(item.url)
                    failureReason = failureReason ?? error.localizedDescription
                    continue
                }
                // Root-owned: fold into one admin batch.
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

        func outcome(failed extra: [URL], cancelled: Bool) -> Outcome {
            // Nothing landed in the box — every item lived on another volume, was
            // skipped, or the admin batch never ran. Don't leave a dated folder
            // behind in the Trash for the user to wonder about.
            if (try? fm.contentsOfDirectory(atPath: box.path))?.isEmpty == true, box != TrashBox.trashRoot {
                try? fm.removeItem(at: box)
            }
            return finish(Outcome(trashed: trashed, failed: failed + extra, skipped: skipped,
                                  cancelled: cancelled, failureReason: failureReason))
        }

        guard !privilegedPairs.isEmpty else { return outcome(failed: [], cancelled: false) }

        // `moveCommands` drops any pair that fails the protected/symlink re-check,
        // so only record/report the ones it will actually move. What it filtered
        // out was left alone on purpose, which is what `skipped` means — never
        // record it as recoverable, and never call it a failure.
        // One decision per URL, so the set we report and the set the batch moves
        // can't disagree if a path changes underneath us.
        let byMovable = Dictionary(grouping: privilegedURLs) { PrivilegedRunner.isSafeToMove($0.path) }
        let movableURLs = byMovable[true] ?? []
        skipped.append(contentsOf: byMovable[false] ?? [])
        let commands = PrivilegedRunner.moveCommands(container: box.path, pairs: privilegedPairs)
        guard !commands.isEmpty else { return outcome(failed: [], cancelled: false) }

        // The batch is one `mv` per file joined by `;`, so its exit status speaks
        // only for the last one — and a throw does not mean nothing moved. Every
        // way out of here asks the disk instead, or a file already sitting in the
        // Trash gets reported as unremovable and recorded nowhere.
        func settle(cancelled: Bool) -> Outcome {
            let landedPaths = Set(privilegedPairs.filter { fm.fileExists(atPath: $0.dest) }.map(\.src))
            trashed.append(contentsOf: movableURLs.filter { landedPaths.contains($0.path) })
            let stranded = movableURLs.filter { !landedPaths.contains($0.path) }
            if !stranded.isEmpty, !cancelled {
                failureReason = failureReason ?? "the administrator command did not move them"
            }
            return outcome(failed: stranded, cancelled: cancelled)
        }

        do {
            try PrivilegedRunner.runBatch(commands)
            return settle(cancelled: false)
        } catch PrivilegedRunner.RunError.cancelled {
            return settle(cancelled: true)
        } catch {
            // Through `localizedDescription`, not the raw associated value: that is
            // where multi-line osascript stderr gets collapsed into a sentence.
            failureReason = failureReason ?? error.localizedDescription
            return settle(cancelled: false)
        }
    }
}
