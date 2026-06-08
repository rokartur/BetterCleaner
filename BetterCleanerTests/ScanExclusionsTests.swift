import Testing
import Foundation
@testable import BetterCleaner

@Suite struct ScanExclusionsTests {
    private let excluded: Set<String> = ["/Users/me/Library/Caches", "/data/keep"]

    @Test func exactPathIsExcluded() {
        #expect(ScanExclusions.isExcluded(URL(fileURLWithPath: "/Users/me/Library/Caches"), in: excluded))
    }

    @Test func childPathIsExcluded() {
        #expect(ScanExclusions.isExcluded(URL(fileURLWithPath: "/Users/me/Library/Caches/com.foo.Bar"), in: excluded))
        #expect(ScanExclusions.isExcluded(URL(fileURLWithPath: "/data/keep/deep/nested/file.txt"), in: excluded))
    }

    @Test func siblingPathIsNotExcluded() {
        // A path that merely shares a string prefix but not a path boundary.
        #expect(!ScanExclusions.isExcluded(URL(fileURLWithPath: "/Users/me/Library/CachesOther"), in: excluded))
        #expect(!ScanExclusions.isExcluded(URL(fileURLWithPath: "/Users/me/Library/Logs"), in: excluded))
    }

    @Test func emptySetExcludesNothing() {
        #expect(!ScanExclusions.isExcluded(URL(fileURLWithPath: "/Users/me/Library/Caches"), in: []))
    }

    @Test func setStandardizesPaths() {
        let set = ScanExclusions.set(from: [URL(fileURLWithPath: "/tmp/../data/keep")])
        #expect(set.contains("/data/keep"))
    }

    @Test func userTrashPathsAreInTrash() {
        #expect(ScanExclusions.isInTrash("/Users/me/.Trash/Foo.app"))
        // A just-uninstalled bundle inside BetterCleaner's per-removal Trash box.
        #expect(ScanExclusions.isInTrash("/Users/me/.Trash/Foo — 2026-06-03/Data/Library/Application Support/foo"))
    }

    @Test func volumeTrashesPathsAreInTrash() {
        #expect(ScanExclusions.isInTrash("/Volumes/USB/.Trashes/501/Foo.app"))
    }

    @Test func nonTrashPathsAreNotInTrash() {
        #expect(!ScanExclusions.isInTrash("/Users/me/Library/Application Support/Foo"))
        #expect(!ScanExclusions.isInTrash("/Applications/Foo.app"))
        // ".Trash" only as part of a name, not a path component, must not match.
        #expect(!ScanExclusions.isInTrash("/Users/me/MyTrashStuff/file"))
    }
}
