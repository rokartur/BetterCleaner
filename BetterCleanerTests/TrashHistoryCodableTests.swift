import Testing
import Foundation
@testable import BetterCleaner

@Suite struct TrashHistoryCodableTests {
    @Test func legacyEntryWithoutFilesDecodes() throws {
        // Pre-FileRecord history has no "files" key; it must still decode.
        let json = """
        [{"date":"2024-01-02T03:04:05Z","origin":"Foo","count":2,"bytes":123,"paths":["/a","/b"]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([TrashHistory.Entry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].files == nil)
        #expect(entries[0].paths == ["/a", "/b"])
        #expect(entries[0].origin == "Foo")
    }

    @Test func entryWithFilesRoundTrips() throws {
        let rec = TrashHistory.FileRecord(originalPath: "/a", trashPath: "/T/a", domain: "user", recoverable: true)
        let nonRec = TrashHistory.FileRecord(originalPath: "pkg receipt: com.foo", trashPath: nil, domain: "system", recoverable: false)
        let entry = TrashHistory.Entry(date: Date(timeIntervalSince1970: 1000), origin: "Foo", count: 2, bytes: 10, paths: ["/a", "pkg receipt: com.foo"], files: [rec, nonRec])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode([TrashHistory.Entry].self, from: encoder.encode([entry]))

        #expect(back[0].files?.count == 2)
        #expect(back[0].files?[0].trashPath == "/T/a")
        #expect(back[0].files?[0].recoverable == true)
        #expect(back[0].files?[1].recoverable == false)
        #expect(back[0].files?[1].trashPath == nil)
    }
}
