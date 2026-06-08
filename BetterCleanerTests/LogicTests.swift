import Testing
import Foundation
@testable import BetterCleaner

@Suite struct LocationsTests {
    @Test func categoryOrderLeadsWithApplication() {
        #expect(Locations.categoryOrder.first == "Application")
        #expect(Locations.categoryOrder.contains("Caches"))
        #expect(Locations.categoryOrder.contains("Preferences"))
        #expect(Locations.categoryOrder.contains("Containers"))
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
        InstalledApp(url: URL(fileURLWithPath: "/Applications/Foo.app"), bundleID: "com.foo.Bar", name: "Bar", isSystem: false),
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
        let idx = InstalledAppsIndex(apps: [
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Foo.app"),
                         bundleID: "com.foo.Bar", name: "Bar",
                         extraBundleIDs: ["com.foo.Helper"], isSystem: false),
        ])
        #expect(idx.ownsIdentifier("com.foo.Helper"))
        #expect(idx.ownsIdentifier("com.foo.Helper.xpc"))
        #expect(!idx.ownsIdentifier("com.foo.Other"))
    }
}

@Suite struct ScanSectionTests {
    @Test func sectionsAreOrderedAndSizeSorted() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/a/Caches/x"), category: "Caches", domain: .user, isDirectory: false, size: 10),
            FileItem(url: URL(fileURLWithPath: "/a/Caches/y"), category: "Caches", domain: .user, isDirectory: false, size: 100),
            FileItem(url: URL(fileURLWithPath: "/a/App"), category: "Application", domain: .user, isDirectory: true, size: 5),
        ]
        let sections = LeftoverScanner.sections(from: items)
        // "Application" sorts before "Caches" per categoryOrder.
        #expect(sections.first?.category == "Application")
        // Within a section, larger files come first.
        #expect(sections.last?.items.map(\.size) == [100, 10])
    }
}
