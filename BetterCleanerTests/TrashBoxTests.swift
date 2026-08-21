import Testing
import Foundation
@testable import BetterCleaner

@Suite struct TrashBoxTests {
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
        #expect(Trasher.Outcome(trashed: [url], failed: [url], cancelled: true)
            .incompleteMessage(verb: "moved to Trash")
            == "1 moved to Trash, 1 failed (the administrator prompt was cancelled).")
    }
}
