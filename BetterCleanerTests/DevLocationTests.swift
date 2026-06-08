import Testing
import Foundation
@testable import BetterCleaner

@Suite struct DevLocationTests {
    @Test func allReturnsAbsoluteHomeExpandedPaths() {
        let locations = DevLocations.all()
        #expect(!locations.isEmpty)
        #expect(locations.allSatisfy { $0.path.hasPrefix("/") })
        #expect(locations.allSatisfy { !$0.category.isEmpty })
    }

    @Test func coversKeyEnvironments() {
        let categories = Set(DevLocations.all().map { $0.category })
        #expect(categories.contains("Xcode"))
        #expect(categories.contains("Node"))
        #expect(categories.contains("Rust"))
        // Heavyweight reclaims added from cleaner research (Docker VM, Homebrew cache).
        #expect(categories.contains("Docker"))
        #expect(categories.contains("Homebrew"))
    }

    @Test func askFirstArtifactsAreNotAutoSelectable() {
        // Real artifacts (Docker VM, Maven/Gradle repos, conda pkgs) must never be
        // swept by Select All — only safeCache entries are auto-selectable.
        let docker = DevLocations.all().first { $0.category == "Docker" }
        #expect(docker?.tier == .askFirst)
    }
}
