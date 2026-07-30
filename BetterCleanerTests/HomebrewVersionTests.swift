import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewVersionTests {
    @Test(arguments: [
        ("1.2.10", "1.2.9", ComparisonResult.orderedDescending),
        ("v2.0", "2.0", ComparisonResult.orderedSame),
        ("1.2_1", "1.2", ComparisonResult.orderedDescending),
        ("1.2,345", "1.2,123", ComparisonResult.orderedSame),
    ])
    func comparesHomebrewVersionShapes(lhs: String, rhs: String, expected: ComparisonResult) {
        #expect(HomebrewVersion.compare(lhs, rhs) == expected)
    }

    @Test func latestCasksDoNotProduceSyntheticUpdates() {
        #expect(HomebrewVersion.isAtLeast("2026.7", "latest"))
        #expect(HomebrewVersion.isAtLeast("", "latest"))
    }

    @Test func extractsOnlyUnambiguousCommaBuild() {
        #expect(HomebrewVersion.buildPart("5.7.3,2320") == "2320")
        #expect(HomebrewVersion.buildPart("quail3,AI-261,arm64") == nil)
    }
}
