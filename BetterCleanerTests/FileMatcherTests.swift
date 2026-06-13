import Testing
import Foundation
@testable import BetterCleaner

@Suite struct FileMatcherTests {
    private let bar = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")

    @Test func normalizeStripsNonAlphanumerics() {
        #expect(FileMatcher.normalize("Sublime Text") == "sublimetext")
        #expect(FileMatcher.normalize("VLC.app") == "vlcapp")
        #expect(FileMatcher.normalize("  ") == "")
    }

    @Test func exactBundleIDMatches() {
        #expect(FileMatcher.matches(fileName: "com.foo.Bar", descriptor: bar, sensitivity: .strict))
    }

    @Test func bundleIDPrefixMatchesAtAllLevels() {
        // com.foo.Bar.plist / .savedState are owned by com.foo.Bar even at strict.
        #expect(FileMatcher.matches(fileName: "com.foo.Bar.plist", descriptor: bar, sensitivity: .strict))
        #expect(FileMatcher.matches(fileName: "com.foo.Bar.savedState", descriptor: bar, sensitivity: .strict))
    }

    @Test func bundleIDGluedSuffixIsWeakNotStrong() {
        // "com.foo.BarHelper" is the id with a glued-on suffix (no separator):
        // surfaced for review (weak), never auto-selected — it is indistinguishable
        // from a sibling app "com.foo.Bartender". Strict ignores it entirely. A bare
        // `contains` used to return .strong here and auto-trash both.
        #expect(FileMatcher.match(fileName: "com.foo.BarHelper", descriptor: bar, sensitivity: .strict) == nil)
        #expect(FileMatcher.match(fileName: "com.foo.BarHelper", descriptor: bar, sensitivity: .standard) == .weak)
        // The id as a whole, separator-delimited run inside a longer name stays strong.
        #expect(FileMatcher.match(fileName: "com.apple.sharedfilelist.com.foo.Bar.sfl2", descriptor: bar, sensitivity: .standard) == .strong)
        // A mid-token coincidence (id preceded by alphanumerics) never matches.
        #expect(FileMatcher.match(fileName: "mycom.foo.Barbaz", descriptor: bar, sensitivity: .aggressive) == nil)
    }

    @Test func exactNameMatches() {
        let app = AppDescriptor(bundleID: nil, name: "Sublime Text")
        #expect(FileMatcher.matches(fileName: "Sublime Text", descriptor: app, sensitivity: .strict))
        #expect(FileMatcher.matches(fileName: "SublimeText", descriptor: app, sensitivity: .strict))
    }

    @Test func shortNamesDoNotSubstringMatch() {
        // A 2-char name must not sweep in unrelated files at standard sensitivity.
        let go = AppDescriptor(bundleID: nil, name: "Go")
        #expect(!FileMatcher.matches(fileName: "google.chrome.helper", descriptor: go, sensitivity: .standard))
    }

    @Test func nameSubstringMatchesAtStandard() {
        let app = AppDescriptor(bundleID: nil, name: "Spotify")
        #expect(!FileMatcher.matches(fileName: "com.spotify.client.helper", descriptor: app, sensitivity: .strict))
        #expect(FileMatcher.matches(fileName: "com.spotify.client.helper", descriptor: app, sensitivity: .standard))
    }

    @Test func nonAppleAppNeverMatchesAppleFiles() {
        // An app *named* "Safari"/"Core" must not sweep in com.apple.* files at any
        // sensitivity — only an exact Apple bundle id can.
        let safari = AppDescriptor(bundleID: "com.acme.Safari", name: "Safari")
        #expect(!FileMatcher.matches(fileName: "com.apple.Safari.plist", descriptor: safari, sensitivity: .aggressive))
        let core = AppDescriptor(bundleID: nil, name: "Core")
        #expect(!FileMatcher.matches(fileName: "com.apple.SpeechRecognitionCore.plist", descriptor: core, sensitivity: .aggressive))
    }

    @Test func appleAppMatchesItsOwnFilesByBundleID() {
        let appleSafari = AppDescriptor(bundleID: "com.apple.Safari", name: "Safari")
        #expect(FileMatcher.matches(fileName: "com.apple.Safari.plist", descriptor: appleSafari, sensitivity: .strict))
    }

    @Test func standardMatchesAtTokenBoundaryNotMidIdentifier() {
        let spotify = AppDescriptor(bundleID: nil, name: "Spotify")
        // token "spotify" present → strong at standard
        #expect(FileMatcher.match(fileName: "com.spotify.client", descriptor: spotify, sensitivity: .standard) == .strong)
        // "spotify" only appears mid-token → no standard match; aggressive surfaces
        // it as a weak (manual) match, not an auto-selected strong one.
        #expect(FileMatcher.match(fileName: "multispotify.cache", descriptor: spotify, sensitivity: .standard) == nil)
        #expect(FileMatcher.match(fileName: "multispotify.cache", descriptor: spotify, sensitivity: .aggressive) == .weak)
    }

    @Test func byHostPreferenceMatchesByBundleID() {
        // ByHost prefs look like com.foo.Bar.<UUID>.plist — owned via bundle-id prefix.
        #expect(FileMatcher.matches(fileName: "com.foo.Bar.0000-1111-2222.plist", descriptor: bar, sensitivity: .strict))
    }

    @Test func crashLogMatchesByNameToken() {
        // DiagnosticReports / CrashReporter entries lead with the app name token.
        let app = AppDescriptor(bundleID: nil, name: "Spotify")
        #expect(FileMatcher.matches(fileName: "Spotify_2024-01-01-120000_host.crash", descriptor: app, sensitivity: .standard))
        #expect(FileMatcher.matches(fileName: "Spotify-2024-01-01-120000.ips", descriptor: app, sensitivity: .standard))
    }

    @Test func executableNameIsASearchTerm() {
        // Cache/support folders are often named after CFBundleExecutable, not the
        // display name — so the executable is a first-class match term.
        let app = AppDescriptor(bundleID: nil, name: "Some Display Name", executable: "Hyperterm")
        #expect(FileMatcher.matches(fileName: "Hyperterm", descriptor: app, sensitivity: .strict))
        #expect(FileMatcher.matches(fileName: "hyperterm.settings", descriptor: app, sensitivity: .standard))
    }

    @Test func nestedHelperBundleIDMatches() {
        // A helper's leftovers carry the helper's id; attribute them to the parent.
        let app = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar", extraBundleIDs: ["com.foo.BarHelper"])
        #expect(FileMatcher.matches(fileName: "com.foo.BarHelper.plist", descriptor: app, sensitivity: .strict))
        #expect(FileMatcher.matches(fileName: "com.foo.BarHelper", descriptor: app, sensitivity: .strict))
    }

    @Test func containerMatchesByResolvedIdentifier() {
        let app = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")
        #expect(FileMatcher.containerMatches(identifier: "com.foo.Bar", descriptor: app))
        #expect(FileMatcher.containerMatches(identifier: "com.foo.Bar.viewer", descriptor: app))
        #expect(!FileMatcher.containerMatches(identifier: "com.other.App", descriptor: app))
    }

    @Test func containerIdentifierReadsMetadataPlist() throws {
        // Single bounded temp file — not a real-FS walk.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataIdentifier": "com.foo.Bar"], format: .xml, options: 0)
        try data.write(to: tmp.appendingPathComponent(".com.apple.containermanager.metadata.plist"))
        #expect(FileMatcher.containerIdentifier(of: tmp) == "com.foo.Bar")
        #expect(FileMatcher.containerIdentifier(of: FileManager.default.temporaryDirectory.appendingPathComponent("bc-none-\(UUID().uuidString)")) == nil)
    }

    @Test func looksOpaqueDetectsUUIDAndHashOnly() {
        // UUID-named (sandbox container) and long-hex (content-hash cache) folders
        // are opaque → eligible for the Spotlight-metadata ownership lookup.
        #expect(FileMatcher.looksOpaque("AC7E5B2D-1F3A-4C9E-8B0D-1234567890AB"))
        #expect(FileMatcher.looksOpaque("a1b2c3d4e5f60718"))
        // Human/lexical names are not opaque → never trigger the metadata lookup.
        #expect(!FileMatcher.looksOpaque("com.spotify.client"))
        #expect(!FileMatcher.looksOpaque("Google"))
        #expect(!FileMatcher.looksOpaque("Caches"))
        #expect(!FileMatcher.looksOpaque("1234"))
    }

    @Test func protectedFilesAreGuarded() {
        #expect(FileMatcher.isProtected(url: URL(fileURLWithPath: "/Users/x/Library/Preferences/.GlobalPreferences.plist")))
        #expect(FileMatcher.isProtected(url: URL(fileURLWithPath: "/Users/x/Library/Preferences/com.apple.finder.plist")))
        #expect(!FileMatcher.isProtected(url: URL(fileURLWithPath: "/Users/x/Library/Preferences/com.foo.Bar.plist")))
    }

    @Test func extraNameIsASearchTerm() {
        // CFBundleName often differs from the display name and IS the on-disk
        // support/cache folder: VS Code's display name is "Visual Studio Code" but
        // its folder is "Code". The display name alone would miss it.
        let vscode = AppDescriptor(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
                                   executable: "Electron", extraNames: ["Code"])
        #expect(FileMatcher.matches(fileName: "Code", descriptor: vscode, sensitivity: .standard))
        #expect(FileMatcher.match(fileName: "Code", descriptor: vscode, sensitivity: .standard) == .strong)
        // Still attributed by its bundle id regardless of name.
        #expect(FileMatcher.matches(fileName: "com.microsoft.VSCode.plist", descriptor: vscode, sensitivity: .strict))
    }

    @Test func classifyReportsEvidenceKind() {
        let app = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")
        #expect(FileMatcher.classify(fileName: "com.foo.Bar.plist", descriptor: app, sensitivity: .strict)?.kind == .bundleID)
        let spotify = AppDescriptor(bundleID: "com.spotify.client", name: "Spotify")
        #expect(FileMatcher.classify(fileName: "Spotify.crash", descriptor: spotify, sensitivity: .standard)?.kind == .name)
        let parallels = AppDescriptor(bundleID: "com.parallels.desktop", name: "Parallels Desktop")
        #expect(FileMatcher.classify(fileName: "Parallels", descriptor: parallels, sensitivity: .standard)?.kind == .vendor)
    }

    @Test func nameClaimedByOtherDetectsCollisions() {
        // Two apps could both answer to the folder name "Code". The collision guard
        // sees the rival claim so the scanner keeps the match manual (never
        // auto-trashed under the wrong app). A bundle-id name doesn't collide.
        let rival = AppDescriptor(bundleID: "com.other.CodeRunner", name: "Code")
        #expect(FileMatcher.nameClaimedByOther(fileName: "Code", others: [rival], sensitivity: .standard))
        #expect(!FileMatcher.nameClaimedByOther(fileName: "com.foo.Bar.plist", others: [rival], sensitivity: .standard))
        // A vendor-only rival claim is too weak to veto an otherwise clean name match.
        let vendorRival = AppDescriptor(bundleID: "com.parallels.other", name: "Something Else")
        #expect(!FileMatcher.nameClaimedByOther(fileName: "Parallels", others: [vendorRival], sensitivity: .standard))
    }

    @Test func collisionGuardVetoesOnlyStrongEvidence() {
        // A rival whose name only appears as a mid-string substring (weak/contains)
        // must NOT veto — otherwise any folder containing a 4-char word another app
        // uses gets demoted to manual, which is the over-suppression that made the
        // scan feel "worse". Only an exact / token-boundary / prefix name (strong)
        // or a bundle-id collides.
        let spotify = AppDescriptor(bundleID: nil, name: "Spotify")
        #expect(!FileMatcher.nameClaimedByOther(fileName: "multispotifycache", others: [spotify], sensitivity: .aggressive))
        #expect(FileMatcher.nameClaimedByOther(fileName: "Spotify", others: [spotify], sensitivity: .aggressive))
        #expect(FileMatcher.nameClaimedByOther(fileName: "spotify.cache", others: [spotify], sensitivity: .aggressive))
    }

    @Test func collisionIndexMatchesWrapperSemantics() {
        // The precomputed index must answer identically to the per-app wrapper for a
        // battery of names across sensitivities — proving the precompute changed only
        // speed, not which matches collide.
        let others = [
            AppDescriptor(bundleID: "com.other.CodeRunner", name: "Code"),
            AppDescriptor(bundleID: "com.spotify.client", name: "Spotify"),
            AppDescriptor(bundleID: "com.parallels.other", name: "Something Else"),
            AppDescriptor(bundleID: "com.foo.Bar", name: "Bar", extraBundleIDs: ["com.foo.BarHelper"]),
        ]
        let index = FileMatcher.CollisionIndex(others)
        let names = ["Code", "com.foo.Bar.plist", "Parallels", "Spotify",
                     "multispotifycache", "com.spotify.client.helper", "Unrelated"]
        for sensitivity in [SearchSensitivity.strict, .standard, .aggressive] {
            for name in names {
                #expect(index.claims(fileName: name, sensitivity: sensitivity)
                        == FileMatcher.nameClaimedByOther(fileName: name, others: others, sensitivity: sensitivity))
            }
        }
    }
}
