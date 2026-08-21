import Testing
import Foundation
@testable import BetterCleaner

/// The query builder is the whole of File Search's logic: everything the user
/// picks becomes one `mdfind` predicate, and an unfiltered query would hand back
/// the entire Spotlight index.
@Suite struct FileSearcherQueryTests {
    @Test func nameSearchIsCaseAndDiacriticInsensitiveSubstring() {
        let query = FileSearcher.query(for: .init(text: "invoice"))
        #expect(query == "(kMDItemFSName == \"*invoice*\"cd)")
    }

    @Test func combinesEveryFilterWithAnd() {
        let query = FileSearcher.query(
            for: .init(text: "report", kind: .images, minSize: 10_000_000, withinDays: 7)
        )
        #expect(query == "(kMDItemFSName == \"*report*\"cd) && (kMDItemContentTypeTree == \"public.image\")"
            + " && (kMDItemFSSize >= 10000000) && (kMDItemFSContentChangeDate >= $time.today(-7))")
    }

    @Test func filtersAloneAreEnoughWithoutText() {
        #expect(FileSearcher.query(for: .init(minSize: 1_000_000_000)) == "(kMDItemFSSize >= 1000000000)")
    }

    /// No criteria at all must not become "match everything".
    @Test func emptyCriteriaProduceNoQuery() {
        #expect(FileSearcher.query(for: .init()) == nil)
        #expect(FileSearcher.query(for: .init(text: "   ")) == nil)
        #expect(FileSearcher.Criteria().isEmpty)
    }

    /// Pickers alone are a valid name search; content search has nothing to grep
    /// for without text, however many filters are set.
    @Test func contentSearchRequiresText() {
        #expect(!FileSearcher.Criteria(kind: .applications).isEmpty)
        #expect(FileSearcher.Criteria(match: .contents, kind: .applications, minSize: 10).isEmpty)
        #expect(!FileSearcher.Criteria(text: "password", match: .contents).isEmpty)
    }

    @Test func rawSpotlightQueriesPassThroughUnescaped() {
        let raw = "kMDItemCFBundleIdentifier == \"com.apple.*\""
        #expect(FileSearcher.query(for: .init(text: raw)) == "(\(raw))")
    }

    /// The pickers stay enabled next to a raw query, so they have to keep applying.
    @Test func rawQueriesStillHonourThePickers() {
        let query = FileSearcher.query(for: .init(text: "kMDItemFSOwnerUserID == 0", minSize: 500))
        #expect(query == "(kMDItemFSOwnerUserID == 0) && (kMDItemFSSize >= 500)")
    }

    @Test func quotesInTheNameCannotBreakOutOfThePredicate() {
        let query = FileSearcher.query(for: .init(text: "a\"b"))
        #expect(query == "(kMDItemFSName == \"*a\\\"b*\"cd)")
    }

    /// Requested explicitly: the scope picker starts on "This Mac".
    @Test func searchesTheWholeMacByDefault() {
        #expect(FileSearcher.Criteria().scope == .everywhere)
    }
}

/// The only action this page offers is "move to Trash", and system-owned hits are
/// moved with administrator rights, so what the filter lets through is a
/// data-loss boundary rather than a matter of taste.
@Suite struct FileSearcherReviewableTests {
    @Test(arguments: [
        "/System/Library/CoreServices/Finder.app",
        "/usr/bin/sudo",
        "/usr/local/bin/rg",
        "/bin/sh",
        "/private/etc/sudoers",
        "/private/var/db/dslocal/nodes/Default",
        "/Library/Keychains/System.keychain",
        "/Library/LaunchDaemons/com.apple.something.plist",
        "/Library/Extensions/AppleUSB.kext",
        "/Users/someone/.Trash/old.txt",
    ])
    func bootCriticalPathsAreNeverOffered(path: String) {
        #expect(!FileSearcher.isReviewable(path))
    }

    @Test(arguments: [
        "/Applications/Some App.app",
        "/usrlocal-not-a-system-path/file.txt",
        "/Volumes/Backup/photo.jpg",
    ])
    func ordinaryFilesStayReviewable(path: String) {
        #expect(FileSearcher.isReviewable(path))
    }

    /// ripgrep echoes the root it walked (`/private/etc`), Spotlight reports the
    /// short form (`/etc`); the guard has to recognise both spellings of one file.
    @Test(arguments: ["/private/etc/sudoers", "/private/var/db/x", "/private/tmp", "/private"])
    func privatePrefixedPathsAreGuardedToo(path: String) {
        #expect(!FileSearcher.isReviewable(path))
    }

    /// Containers are never offered as rows: searching "library", "downloads" or a
    /// user name must not put a whole tree in a list whose button says "Move to
    /// Trash". Their contents are what the search is for, and stay reviewable.
    @Test func wholeContainersAreNeverOffered() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for container in ["/", "/Users", "/Users/Shared", "/Users/someone", "/Applications", "/Library",
                          "/Library/Application Support", "/Library/Preferences", "/Volumes",
                          "/Volumes/Backup", "/tmp", home, home + "/Library", home + "/Documents",
                          home + "/Library/Application Support", home + "/.Trash"] {
            #expect(!FileSearcher.isReviewable(container), "\(container) must not be trashable")
        }
    }

    @Test(arguments: [
        "/Users/someone/Documents/notes.txt",
        "/Library/Application Support/Vendor/cache.db",
        "/Volumes/Backup/old",
        "/tmp/build.log",
    ])
    func whatLivesInsideAContainerStaysReviewable(path: String) {
        #expect(FileSearcher.isReviewable(path))
    }
}
