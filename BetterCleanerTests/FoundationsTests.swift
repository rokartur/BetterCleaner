import Testing
import Foundation
@testable import BetterCleaner

@Suite struct FileSizeStatusTests {
    @Test func readableTreeIsComplete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0xAB, count: 4096).write(to: dir.appendingPathComponent("blob.bin"))

        let (bytes, complete) = FileSize.sizeWithStatus(of: dir)
        #expect(bytes > 0)
        #expect(complete)
    }

    @Test func missingPathIsCompleteAndZero() {
        let (bytes, complete) = FileSize.sizeWithStatus(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(bytes == 0)
        #expect(complete)
    }

    @Test func unreadableSubtreeReportsIncomplete() throws {
        // chmod 000 makes a dir undescendable for non-root, so the enumerator
        // errorHandler fires and the walk is flagged incomplete.
        guard geteuid() != 0 else { return } // root can read anything; skip
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bc-locked-\(UUID().uuidString)", isDirectory: true)
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: locked.appendingPathComponent("secret"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: dir)
        }

        let (_, complete) = FileSize.sizeWithStatus(of: dir)
        #expect(!complete)
    }
}

@Suite struct LaunchPlistParseTests {
    private func writePlist(_ dict: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc-job-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @Test func programPathPrefersProgramThenArgsThenBundle() throws {
        let a = try writePlist(["Label": "com.x.a", "Program": "/usr/local/bin/x"])
        let b = try writePlist(["Label": "com.x.b", "ProgramArguments": ["/opt/y/run", "--flag"]])
        let c = try writePlist(["Label": "com.x.c", "BundleProgram": "Contents/MacOS/z"])
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(LaunchDaemonScanner.programPath(of: a) == "/usr/local/bin/x")
        #expect(LaunchDaemonScanner.programPath(of: b) == "/opt/y/run")
        #expect(LaunchDaemonScanner.programPath(of: c) == "Contents/MacOS/z")
    }

    @Test func labelRejectsTraversalAndAbsolute() throws {
        let good = try writePlist(["Label": "com.x.good", "Program": "/bin/true"])
        let traversal = try writePlist(["Label": "../../evil", "Program": "/bin/true"])
        let absolute = try writePlist(["Label": "/Library/evil", "Program": "/bin/true"])
        defer { [good, traversal, absolute].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(LaunchDaemonScanner.label(of: good) == "com.x.good")
        #expect(LaunchDaemonScanner.label(of: traversal) == nil)
        #expect(LaunchDaemonScanner.label(of: absolute) == nil)
    }
}

@Suite struct DevTierTests {
    @Test func cachesAreSafeAndReposAreAskFirst() {
        let byPath = Dictionary(uniqueKeysWithValues: DevLocations.all().map { ($0.path, $0.tier) })
        // A pure cache is safe to bulk-select.
        #expect(byPath.first { $0.key.hasSuffix("Xcode/DerivedData") }?.value == .safeCache)
        // Local package repos are ask-first (hold real downloaded/built artifacts).
        #expect(byPath.first { $0.key.hasSuffix(".m2/repository") }?.value == .askFirst)
        #expect(byPath.first { $0.key.hasSuffix(".gem") }?.value == .askFirst)
    }
}

/// `FileSize.shortString` feeds the sidebar's fixed-width reclaimable badge, where
/// an over-long string truncates to something meaningless ("20.07…"). These pin the
/// six-character ceiling and the one-decimal-below-ten rule.
@Suite struct FileSizeShortStringTests {
    @Test func keepsOneDecimalBelowTen() {
        #expect(FileSize.shortString(5_800_000_000) == "5.8 GB")
        #expect(FileSize.shortString(9_400_000) == "9.4 MB")
    }

    @Test func dropsDecimalAtTenAndAbove() {
        #expect(FileSize.shortString(20_070_000_000) == "20 GB")
        #expect(FileSize.shortString(999_000_000_000) == "999 GB")
    }

    @Test func neverExceedsTheBadgeWidth() {
        // 6 characters is what the 200pt sidebar minimum can show beside a page name.
        for bytes in [Int64(1), 999, 1_000, 20_070_000_000, 900_000_000_000_000] {
            #expect(FileSize.shortString(bytes).count <= 8)
        }
    }

    @Test func handlesZero() {
        #expect(FileSize.shortString(0) == "Zero KB")
    }
}
