import Testing
import Foundation
@testable import BetterCleaner

/// The tight association filter that keeps Spotlight recall from surfacing
/// near-name noise (e.g. "ParallelSession", "ParallelSCSIReporter") while still
/// catching real vendor leftovers outside the Library catalog.
@Suite struct SpotlightAssociatesTests {
    private let parallels = AppDescriptor(
        bundleID: "com.parallels.desktop.console", name: "Parallels Desktop", executable: "Parallels Desktop")

    @Test func acceptsRealVendorLeftovers() {
        #expect(SpotlightScanner.associates("Parallels", parallels))
        #expect(SpotlightScanner.associates("Applications (Parallels)", parallels))
        #expect(SpotlightScanner.associates("parallels.log", parallels))
        #expect(SpotlightScanner.associates("parallels_for_mac.txt", parallels))
        #expect(SpotlightScanner.associates("com.parallels.vm.db", parallels))
        #expect(SpotlightScanner.associates("com.parallels.desktop.console", parallels))
    }

    @Test func matchesByAppName() {
        // Leftovers named after the app are found, even without a usable vendor.
        let discord = AppDescriptor(bundleID: "com.hnc.Discord", name: "Discord")
        #expect(SpotlightScanner.associates("Discord", discord))
        #expect(SpotlightScanner.associates("discord-updater.log", discord))
        #expect(SpotlightScanner.associates("com.hnc.Discord", discord))
    }

    @Test func genericNameWordsAreNotSearched() {
        // An app named "Notes" must not match every "notes" file on disk.
        let notes = AppDescriptor(bundleID: "com.acme.NoteKeeper", name: "Notes")
        #expect(!SpotlightScanner.associates("meeting-notes.txt", notes))
    }

    @Test func developerPathsAreExcluded() {
        // Source files named after the app (the Discord ~/Developer case) are
        // filtered by path, so they never reach the results.
        #expect(SpotlightScanner.isLikelyDeveloperPath("/Users/x/Developer/app/discord-config-view.tsx"))
        #expect(SpotlightScanner.isLikelyDeveloperPath("/Users/x/proj/node_modules/discord.js/index.js"))
        #expect(SpotlightScanner.isLikelyDeveloperPath("/Users/x/code/src/discord.ts"))
        #expect(!SpotlightScanner.isLikelyDeveloperPath("/Users/x/Parallels/Windows 11.pvm"))
        #expect(!SpotlightScanner.isLikelyDeveloperPath("/Users/Shared/Parallels"))
    }

    @Test func rejectsNearNameNoise() {
        // "parallels" is a *prefix* of these tokens but not a whole token → reject.
        #expect(!SpotlightScanner.associates("ParallelSession.pm", parallels))
        #expect(!SpotlightScanner.associates("SPParallelSCSIReporter.spreporter", parallels))
        #expect(!SpotlightScanner.associates("ParallelSession.3pm", parallels))
        // Unrelated entirely.
        #expect(!SpotlightScanner.associates("Spotify", parallels))
        #expect(!SpotlightScanner.associates("Paragon NTFS", parallels))
    }

    @Test func declaredExecutableAndAlternateNamesAreSignals() {
        let app = AppDescriptor(
            bundleID: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            executable: "Code",
            extraNames: ["Code - Insiders"]
        )

        #expect(SpotlightScanner.associates("Code Cache", app))
        #expect(SpotlightScanner.associates("code-insiders.log", app))
    }

    @Test func oneMetadataQueryCoversFilenamesAndBundleMetadata() {
        let query = SpotlightScanner.metadataQuery(for: parallels)

        #expect(query?.contains("kMDItemFSName") == true)
        #expect(query?.contains("*com.parallels.desktop.console*") == true)
        #expect(query?.contains("kMDItemCFBundleIdentifier") == true)
    }
}
