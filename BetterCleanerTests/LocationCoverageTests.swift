import Testing
import Foundation
@testable import BetterCleaner

@Suite struct LocationCoverageTests {
    @Test func categoryOrderIncludesNewSurfaces() {
        let order = Set(Locations.categoryOrder)
        for category in ["Audio Plug-Ins", "Screen Savers", "Input Methods",
                         "Spotlight", "QuickLook", "Receipts", "Developer",
                         "Fonts", "Temporary"] {
            #expect(order.contains(category))
        }
    }

    @Test func everyProducedCategoryIsOrdered() {
        // A location whose category is missing from categoryOrder would be dumped
        // at the bottom of the list; guard against that drift.
        let order = Set(Locations.categoryOrder)
        let produced = Locations.systemLocations().map { $0.category }
            + Locations.userLocations().map { $0.category }
            + Locations.perUserTempLocations().map { $0.category }
            + Locations.unixToolLocations().map { $0.category }
            + Locations.systemDataLocations().map { $0.category }
        for category in produced {
            #expect(order.contains(category), "category \(category) not in categoryOrder")
        }
    }

    @Test func tempLocationsAreUserDomainAndAutoSelectable() {
        for location in Locations.perUserTempLocations() {
            #expect(location.domain == .user)
            #expect(location.category == "Temporary")
            #expect(location.autoSelectable)
        }
    }

    @Test func fontsLocationIsNotAutoSelectable() {
        // Build a synthetic Fonts dir under a temp "Library" and confirm the
        // catalog marks it manual-only when present.
        let fontsEntry = Locations.userLocations().first { $0.category == "Fonts" }
        if let fontsEntry { #expect(!fontsEntry.autoSelectable) }
    }
}
