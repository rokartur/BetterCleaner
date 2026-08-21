import Testing
import Foundation
@testable import BetterCleaner

@Suite struct TrashBoxTests {
    /// These reach the user verbatim as the reason a file survived. A bare Swift
    /// error enum renders as "RunError error 0", which explains nothing.
    @Test func privilegedFailuresReadAsSentences() {
        #expect(PrivilegedRunner.RunError.failed("No such file").localizedDescription == "No such file")
        #expect(PrivilegedRunner.RunError.cancelled.localizedDescription
            == "the administrator prompt was cancelled")

        // The batch is one `mv` per file, so a multi-file failure yields several
        // stderr lines that have to fit inside a sentence.
        let batch = PrivilegedRunner.RunError.failed("mv: a: Permission denied\nmv: b: Read-only file system\n")
        #expect(batch.localizedDescription == "mv: a: Permission denied; mv: b: Read-only file system")
        #expect(PrivilegedRunner.RunError.failed(String(repeating: "x", count: 500))
            .localizedDescription.count == 201)

        // A silent failure still has to read as a reason, never as an empty gap
        // in "1 failed ()."
        #expect(PrivilegedRunner.RunError.failed("  \n ").localizedDescription
            == "the command failed without saying why")
    }

    /// The report has to separate "this failed" from "this was left alone on
    /// purpose". The reason belongs to the summary sentence above the list, so the
    /// headings must not repeat it.
    @Test @MainActor func theReportSeparatesFailuresFromDeliberateSkips() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/x")
        let outcome = Trasher.Outcome(trashed: [], failed: [home], skipped: [URL(fileURLWithPath: "/etc/hosts")],
                                      cancelled: false, failureReason: "Read-only volume")
        let body = RemovalReportViewController.body(for: outcome)

        #expect(body.contains("COULD NOT BE REMOVED\n"))
        #expect(!body.contains("Read-only volume"))
        #expect(outcome.incompleteMessage(verb: "removed")?.contains("Read-only volume") == true)
        #expect(body.contains("  ~/Library/Caches/x"))
        #expect(body.contains("LEFT IN PLACE"))
        #expect(body.contains("  /etc/hosts"))

        // A clean run has nothing to show, and no empty headings either.
        let clean = Trasher.Outcome(trashed: [home], failed: [], cancelled: false)
        #expect(RemovalReportViewController.body(for: clean).isEmpty)
    }

    /// Revealing opens one Finder window per folder, so a wide spread must not offer it.
    @Test @MainActor func revealIsOfferedOnlyForAFewFolders() {
        let spread = (1...6).map { URL(fileURLWithPath: "/Library/App\($0)/Base.lproj") }
        #expect(!RemovalReportViewController.revealFitsInFinder(spread))
        #expect(RemovalReportViewController.revealFitsInFinder(Array(spread.prefix(5))))

        // Many files, one folder: still a single window.
        let together = (1...40).map { URL(fileURLWithPath: "/Library/App/\($0).lproj") }
        #expect(RemovalReportViewController.revealFitsInFinder(together))
        #expect(!RemovalReportViewController.revealFitsInFinder([]))
    }

    @Test func folderNameSanitizesAndDates() {
        let name = TrashBox.folderName(origin: "Parallels/Desktop: Pro", at: Date(timeIntervalSince1970: 0))
        // Path-unsafe characters replaced; origin and date joined by " — ".
        #expect(name.hasPrefix("Parallels-Desktop- Pro — "))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test func folderNameFallsBackForBlankOrigin() {
        #expect(TrashBox.folderName(origin: "   ", at: Date(timeIntervalSince1970: 0)).hasPrefix("BetterCleaner — "))
    }

    @Test func uniqueNameAvoidsCollisionsInSet() {
        let box = URL(fileURLWithPath: "/tmp/nonexistent-box-\(UUID().uuidString)")
        var used = Set<String>()
        #expect(TrashBox.uniqueName(in: box, for: "data", used: &used) == "data")
        #expect(TrashBox.uniqueName(in: box, for: "data", used: &used) == "data (2)")
        #expect(TrashBox.uniqueName(in: box, for: "data", used: &used) == "data (3)")
        // Extension is preserved across the suffix.
        #expect(TrashBox.uniqueName(in: box, for: "log.txt", used: &used) == "log.txt")
        #expect(TrashBox.uniqueName(in: box, for: "log.txt", used: &used) == "log (2).txt")
    }

    @Test func uniqueNameAvoidsExistingFilesOnDisk() throws {
        let fm = FileManager.default
        let box = fm.temporaryDirectory.appendingPathComponent("bc-box-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: box, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: box) }
        try "x".write(to: box.appendingPathComponent("data"), atomically: true, encoding: .utf8)

        var used = Set<String>()
        // "data" exists on disk → first free name is "data (2)".
        #expect(TrashBox.uniqueName(in: box, for: "data", used: &used) == "data (2)")
    }

    /// Firmlinked system paths must read as the same volume as the Trash: were
    /// they seen as foreign, every root-owned removal would quietly stop asking
    /// for a password and start failing instead.
    @Test(arguments: ["/Library", "/Applications", "/usr/local", "/private/var/db",
                      NSHomeDirectory(), "/nope-does-not-exist"])
    func systemPathsShareTheTrashVolume(path: String) {
        #expect(TrashBox.isOnTrashVolume(URL(fileURLWithPath: path)))
    }

    /// The decision between an admin prompt and giving up on the user's file.
    @Test func onlyPermissionErrorsAreWorthAPasswordPrompt() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                                     code: Int(EACCES))])
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                                       code: Int(EROFS))])
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [:])
        #expect(Trasher.isPermissionDenied(denied))
        #expect(!Trasher.isPermissionDenied(readOnly))
        #expect(!Trasher.isPermissionDenied(full))
    }

    /// A removal that left anything behind has to say so: a skipped item is not a
    /// failure, but reporting only the trashed count reads as full success.
    @Test func incompleteMessageNamesFailuresAndSkips() {
        let url = URL(fileURLWithPath: "/tmp/x")
        #expect(Trasher.Outcome(trashed: [url], failed: [], cancelled: false)
            .incompleteMessage(verb: "moved to Trash") == nil)

        let readOnly = Trasher.Outcome(trashed: [], failed: [url], cancelled: false,
                                       failureReason: "The volume is read only.")
        #expect(readOnly.incompleteMessage(verb: "moved to Trash")
            == "0 moved to Trash, 1 failed (The volume is read only).")

        let skipped = Trasher.Outcome(trashed: [url], failed: [], skipped: [url, url], cancelled: false)
        #expect(skipped.incompleteMessage(verb: "moved to Trash")
            == "2 items were left in place (protected or a link).")

        // The user pressed Cancel and nothing moved: they don't need telling.
        #expect(Trasher.Outcome(trashed: [], failed: [url], cancelled: true)
            .incompleteMessage(verb: "moved to Trash") == nil)

        // ...but a skip was decided before any password was asked for, so
        // cancelling doesn't explain it away. Once the sheet opens it lists the
        // failures too, so the summary has to account for them.
        #expect(Trasher.Outcome(trashed: [], failed: [url], skipped: [url], cancelled: true)
            .incompleteMessage(verb: "moved to Trash")
            == "0 moved to Trash, 1 failed (the administrator prompt was cancelled)."
            + "\n\n1 item was left in place (protected or a link).")
        #expect(Trasher.Outcome(trashed: [url], failed: [url], cancelled: true)
            .incompleteMessage(verb: "moved to Trash")
            == "1 moved to Trash, 1 failed (the administrator prompt was cancelled).")
    }
}
