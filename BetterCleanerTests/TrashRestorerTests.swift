import Testing
import Foundation
@testable import BetterCleaner

@Suite struct TrashRestorerTests {

    // MARK: - moveBackCommands (pure)

    @Test func moveBackCommandsBuildsMkdirThenMove() {
        let rec = TrashHistory.FileRecord(
            originalPath: "/Library/Application Support/Foo/data",
            trashPath: "/Users/me/.Trash/data", domain: "system", recoverable: true)
        let cmds = TrashRestorer.moveBackCommands(for: [rec])
        #expect(cmds.count == 2)
        #expect(cmds[0].hasPrefix("mkdir -p "))
        #expect(cmds[0].contains("/Library/Application Support/Foo"))
        #expect(cmds[1].hasPrefix("/bin/mv "))
        #expect(cmds[1].contains("/Users/me/.Trash/data"))
        #expect(cmds[1].contains("/Library/Application Support/Foo/data"))
    }

    @Test func moveBackSkipsNonRecoverableAndMissingTrashPath() {
        let nonRecoverable = TrashHistory.FileRecord(originalPath: "/x/a", trashPath: "/T/a", domain: "system", recoverable: false)
        let noTrashPath = TrashHistory.FileRecord(originalPath: "/x/b", trashPath: nil, domain: "system", recoverable: true)
        #expect(TrashRestorer.moveBackCommands(for: [nonRecoverable, noTrashPath]).isEmpty)
    }

    @Test func moveBackSkipsProtectedTarget() {
        let rec = TrashHistory.FileRecord(
            originalPath: "/x/com.apple.finder.plist",
            trashPath: "/T/com.apple.finder.plist", domain: "system", recoverable: true)
        #expect(TrashRestorer.moveBackCommands(for: [rec]).isEmpty)
    }

    // MARK: - restorable (filesystem)

    @Test func restorableFiltersByExistenceAndOccupancy() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bc-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let trashFile = tmp.appendingPathComponent("trashed.txt")
        try "x".write(to: trashFile, atomically: true, encoding: .utf8)
        let freeOriginal = tmp.appendingPathComponent("gone/original.txt").path

        let ok = TrashHistory.FileRecord(originalPath: freeOriginal, trashPath: trashFile.path, domain: "user", recoverable: true)
        #expect(TrashRestorer.restorable([ok]).count == 1)

        let missingTrash = TrashHistory.FileRecord(originalPath: freeOriginal, trashPath: tmp.appendingPathComponent("nope.txt").path, domain: "user", recoverable: true)
        #expect(TrashRestorer.restorable([missingTrash]).isEmpty)

        // Original location already occupied → not restorable (never clobber).
        let occupied = TrashHistory.FileRecord(originalPath: trashFile.path, trashPath: trashFile.path, domain: "user", recoverable: true)
        #expect(TrashRestorer.restorable([occupied]).isEmpty)
    }

    // MARK: - restore round-trip (user domain, no elevation)

    @Test func restoresUserFileToOriginal() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bc-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let trashFile = tmp.appendingPathComponent("trash/data.txt")
        try fm.createDirectory(at: trashFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hello".write(to: trashFile, atomically: true, encoding: .utf8)
        let original = tmp.appendingPathComponent("orig/data.txt") // parent + file absent

        let rec = TrashHistory.FileRecord(originalPath: original.path, trashPath: trashFile.path, domain: "user", recoverable: true)
        let result = TrashRestorer.restore([rec])

        #expect(result.restored == [original.path])
        #expect(result.failed.isEmpty)
        #expect(fm.fileExists(atPath: original.path))
        #expect(!fm.fileExists(atPath: trashFile.path))
    }
}
