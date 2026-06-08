import Testing
import Foundation
@testable import BetterCleaner

/// The vendor fallback that fixes under-matching of apps like Parallels Desktop
/// (bundle id com.parallels.desktop.console) whose leftovers are named after the
/// vendor ("Parallels", "Parallels Software", "com.parallels.*").
@Suite struct VendorMatchTests {
    private let parallels = AppDescriptor(
        bundleID: "com.parallels.desktop.console", name: "Parallels Desktop", executable: "Parallels Desktop")

    @Test func bundleIDIsStrong() {
        #expect(FileMatcher.match(fileName: "com.parallels.desktop.console", descriptor: parallels, sensitivity: .standard) == .strong)
        #expect(FileMatcher.match(fileName: "com.parallels.desktop.console.plist", descriptor: parallels, sensitivity: .standard) == .strong)
    }

    @Test func vendorNamespaceIsWeak() {
        // Same reverse-DNS vendor namespace, different product → surfaced, manual.
        #expect(FileMatcher.match(fileName: "com.parallels.Parallels Desktop.plist", descriptor: parallels, sensitivity: .standard) == .weak)
        #expect(FileMatcher.match(fileName: "com.parallels.vm.db", descriptor: parallels, sensitivity: .standard) == .weak)
    }

    @Test func vendorFolderNameIsWeak() {
        #expect(FileMatcher.match(fileName: "Parallels", descriptor: parallels, sensitivity: .standard) == .weak)
        #expect(FileMatcher.match(fileName: "Parallels Software", descriptor: parallels, sensitivity: .standard) == .weak)
    }

    @Test func unrelatedNeverMatches() {
        #expect(FileMatcher.match(fileName: "com.apple.dock", descriptor: parallels, sensitivity: .standard) == nil)
        #expect(FileMatcher.match(fileName: "Spotify", descriptor: parallels, sensitivity: .standard) == nil)
        #expect(FileMatcher.match(fileName: "Paragon", descriptor: parallels, sensitivity: .standard) == nil)
    }

    @Test func strictIgnoresVendorFallback() {
        #expect(FileMatcher.match(fileName: "Parallels", descriptor: parallels, sensitivity: .strict) == nil)
        #expect(FileMatcher.match(fileName: "com.parallels.vm.db", descriptor: parallels, sensitivity: .strict) == nil)
    }

    @Test func sharedVendorStaysWeakNotStrong() {
        // com.google.* apps must NOT strong-match the shared "Google" folder, or
        // uninstalling Chrome would auto-select Drive/Keystone data.
        let chrome = AppDescriptor(bundleID: "com.google.Chrome", name: "Google Chrome", executable: "Google Chrome")
        #expect(FileMatcher.match(fileName: "Google", descriptor: chrome, sensitivity: .standard) == .weak)
    }

    @Test func shortVendorComponentIsIgnored() {
        // com.foo.Bar → vendor "foo" is too short to be a token; no false vendor hits.
        let bar = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")
        #expect(FileMatcher.match(fileName: "foozone", descriptor: bar, sensitivity: .standard) == nil)
        #expect(FileMatcher.match(fileName: "com.foo.Other", descriptor: bar, sensitivity: .standard) == nil)
    }

    @Test func vendorTokensExtraction() {
        #expect(FileMatcher.vendorTokens(parallels) == ["parallels"])
        // Generic/short second components yield no vendor token.
        #expect(FileMatcher.vendorTokens(AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")).isEmpty)
        #expect(FileMatcher.vendorTokens(AppDescriptor(bundleID: "com.apple.Safari", name: "Safari")).isEmpty)
    }
}
