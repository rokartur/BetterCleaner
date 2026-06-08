import Testing
import Foundation
@testable import BetterCleaner

@Suite struct PackageBOMFilterTests {
    @Test func collapsesBundleInternalsToRoot() {
        #expect(PackageBOMFilter.collapseBundle("/Applications/Foo.app/Contents/MacOS/Foo") == "/Applications/Foo.app")
        #expect(PackageBOMFilter.collapseBundle("/Library/Audio/Plug-Ins/Components/Bar.component/Contents/x") == "/Library/Audio/Plug-Ins/Components/Bar.component")
        #expect(PackageBOMFilter.collapseBundle("/usr/local/bin/tool") == "/usr/local/bin/tool")
    }

    @Test func removesRedundantChildPaths() {
        let input = ["/a", "/a/b", "/c", "/a/d/e"]
        #expect(PackageBOMFilter.removeRedundantChildPaths(input) == ["/a", "/c"])
    }

    @Test func keepsSiblingThatSortsBetweenParentAndChild() {
        // "/a.txt" sorts between "/a" and "/a/b" but is NOT a child of "/a".
        let input = ["/a", "/a.txt", "/a/b"]
        #expect(PackageBOMFilter.removeRedundantChildPaths(input).sorted() == ["/a", "/a.txt"])
    }

    @Test func filterDropsBareSystemDirsAndForks() {
        let input = [
            "/Applications",                                  // bare system dir → dropped
            "/Applications/Foo.app/Contents/MacOS/Foo",       // collapses to /Applications/Foo.app
            "/Library/Application Support/Foo/data",          // kept
            "/Library/Application Support/Foo/._data",        // resource fork → dropped
            "/usr",                                           // bare system dir → dropped
        ]
        let out = PackageBOMFilter.filter(input)
        #expect(out.contains("/Applications/Foo.app"))
        #expect(out.contains("/Library/Application Support/Foo/data"))
        #expect(!out.contains("/Applications"))
        #expect(!out.contains("/usr"))
        #expect(!out.contains { $0.hasSuffix("._data") })
    }

    @Test func filterCollapsesThenDedupesBundleFiles() {
        let input = [
            "/Applications/Foo.app/Contents/Info.plist",
            "/Applications/Foo.app/Contents/MacOS/Foo",
            "/Applications/Foo.app/Contents/Resources/x.png",
        ]
        // All three collapse to the same bundle root → one entry.
        #expect(PackageBOMFilter.filter(input) == ["/Applications/Foo.app"])
    }
}
