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
}
