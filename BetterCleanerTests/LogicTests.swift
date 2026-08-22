import Testing
import Foundation
@testable import BetterCleaner

@Suite struct LocationsTests {
    @Test func categoryOrderLeadsWithApplication() {
        #expect(Locations.categoryOrder.first == "Application")
        #expect(Locations.categoryOrder.contains("Caches"))
        #expect(Locations.categoryOrder.contains("Preferences"))
        #expect(Locations.categoryOrder.contains("Containers"))
        #expect(Locations.categoryOrder.contains("Frameworks"))
        #expect(Locations.categoryOrder.contains("Scripting Additions"))
    }

    @Test func userLocationsAreUserDomain() {
        #expect(Locations.userLocations().allSatisfy { $0.domain == .user })
    }

    @Test func systemLocationsAreSystemDomain() {
        #expect(Locations.systemLocations().allSatisfy { $0.domain == .system })
    }

    @Test func includeSystemAddsLocations() {
        let userOnly = Locations.locations(includeSystem: false).count
        let withSystem = Locations.locations(includeSystem: true).count
        #expect(withSystem >= userOnly)
    }
}

@Suite struct InstalledAppsIndexTests {
    private let index = InstalledAppsIndex(apps: [
        InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Foo.app"),
            bundleID: "com.foo.Bar",
            name: "Bar",
            isSystem: false
        )
    ])

    @Test func ownsExactAndSuffixedIdentifiers() {
        #expect(index.ownsIdentifier("com.foo.Bar"))
        #expect(index.ownsIdentifier("com.foo.Bar.helper"))
        #expect(!index.ownsIdentifier("com.other.App"))
    }

    @Test func matchesNormalizedName() {
        #expect(index.matchesName("Bar"))
        #expect(!index.matchesName("Baz"))
    }

    @Test func ownsNestedHelperIdentifiers() {
        let index = InstalledAppsIndex(apps: [
            InstalledApp(
                url: URL(fileURLWithPath: "/Applications/Foo.app"),
                bundleID: "com.foo.Bar",
                name: "Bar",
                extraBundleIDs: ["com.foo.Helper"],
                isSystem: false
            )
        ])
        #expect(index.ownsIdentifier("com.foo.Helper"))
        #expect(index.ownsIdentifier("com.foo.Helper.xpc"))
        #expect(!index.ownsIdentifier("com.foo.Other"))
    }
}

@Suite struct CancellationTests {
    @Test func fileSizeStopsBeforeReadingWhenCancelled() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = FileSize.sizeWithStatus(of: file, isCancelled: { true })

        #expect(result.bytes == 0)
        #expect(!result.complete)
    }

    @Test func commandRunnerTerminatesCancelledProcess() {
        var cancellationChecks = 0
        let output = CommandRunner.run("/bin/sleep", ["5"]) {
            cancellationChecks += 1
            return cancellationChecks > 1
        }

        #expect(output.status == CommandRunner.cancelledStatus)
    }
}

@Suite struct ScanSectionTests {
    @Test func sectionsAreOrderedAndSizeSorted() {
        let items = [
            FileItem(
                url: URL(fileURLWithPath: "/a/Caches/x"),
                category: "Caches",
                domain: .user,
                isDirectory: false,
                size: 10
            ),
            FileItem(
                url: URL(fileURLWithPath: "/a/Caches/y"),
                category: "Caches",
                domain: .user,
                isDirectory: false,
                size: 100
            ),
            FileItem(
                url: URL(fileURLWithPath: "/a/App"),
                category: "Application",
                domain: .user,
                isDirectory: true,
                size: 5
            )
        ]
        let sections = LeftoverScanner.sections(from: items)
        // "Application" sorts before "Caches" per categoryOrder.
        #expect(sections.first?.category == "Application")
        // Within a section, larger files come first.
        #expect(sections.last?.items.map(\.size) == [100, 10])
    }
}

@Suite struct SystemBundleTests {
    /// Safari is the reason this exists: Apple links it into `/Applications` from
    /// a cryptex, so only its SIP flag — not its path — marks it as Apple's.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Safari.app"), "host has no Safari"))
    func sipRestrictedBundleOutsideSystemCountsAsSystem() {
        #expect(AppFinder.isSystemBundle(URL(fileURLWithPath: "/Applications/Safari.app")))
    }

    @Test func pathUnderSystemCountsAsSystem() {
        #expect(AppFinder.isSystemBundle(URL(fileURLWithPath: "/System/Applications/Music.app")))
    }

    @Test func ordinaryBundleIsRemovable() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BetterCleanerTest-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(!AppFinder.isSystemBundle(bundle))
    }

    /// Unreadable means unknown, and unknown must not authorise a delete.
    @Test func missingBundleCountsAsSystem() {
        #expect(AppFinder.isSystemBundle(URL(fileURLWithPath: "/Applications/NoSuchApp-\(UUID()).app")))
    }
}
