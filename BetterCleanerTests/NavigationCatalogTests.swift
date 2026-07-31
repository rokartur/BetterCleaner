import Testing
import Foundation
@testable import BetterCleaner

/// The Homebrew sidebar rows were collapsed to a single "Homebrew" entry, with the
/// four categories switching inside the list column and Auto Update / Maintenance
/// moving to that column's ⋯ menu. The page ids stayed — the Finder extension, the
/// Window menu and `MainSplitViewController.select(_:)` all route by id, so a page
/// that lost its row must still resolve. These pin that.
@Suite struct NavigationCatalogTests {
    /// Every id `MainSplitViewController` can be asked to route to.
    private static let routableIDs = [
        "applications", "junk", "orphaned", "pkg", "devenv", "history",
        "brew.installed", "brew.available", "brew.services", "brew.taps",
        "brew.autoupdate", "brew.maintenance",
    ]

    @Test func everyRoutablePageResolves() {
        for id in Self.routableIDs {
            #expect(NavCatalog.section(id: id) != nil, "page id \(id) no longer resolves")
        }
    }

    @Test func homebrewOwnsOneSidebarRow() {
        let rows = NavCatalog.groups.flatMap(\.items)
        let brewRows = rows.filter { $0.id.hasPrefix("brew.") }
        #expect(brewRows.count == 1)
        #expect(brewRows.first?.id == "brew.installed")
    }

    /// Cleanup is what the app is for; it must not be outnumbered in the sidebar by
    /// any single tool again.
    @Test func cleanupIsTheLargestSidebarGroup() {
        let counts = NavCatalog.groups.map(\.items.count)
        let cleanup = NavCatalog.groups.first { $0.title == "Cleanup" }?.items.count ?? 0
        #expect(cleanup == counts.max())
    }

    @Test func unlistedPagesHaveNoSidebarRow() {
        let rowIDs = Set(NavCatalog.groups.flatMap(\.items).map(\.id))
        for section in NavCatalog.unlisted {
            #expect(!rowIDs.contains(section.id), "\(section.id) should not own a sidebar row")
        }
    }
}

/// Homebrew cask versions arrive as `version,build` ("1.1.16,20260425132215"). The
/// build id changes no decision and doubled the width of the list's version column,
/// so the row shows the recognisable part and keeps the rest in the tooltip.
@Suite struct HomebrewShortVersionTests {
    @Test func trimsTheBuildIdentifier() {
        #expect(HomebrewRowCell.shortVersion("1.1.16,20260425132215") == "1.1.16")
    }

    @Test func leavesPlainVersionsAlone() {
        #expect(HomebrewRowCell.shortVersion("5.2.0") == "5.2.0")
        #expect(HomebrewRowCell.shortVersion("2026.0324") == "2026.0324")
    }

    @Test func handlesEmptyAndEdgeCases() {
        #expect(HomebrewRowCell.shortVersion("") == "")
        // Nothing before the comma: fall back to the raw string rather than
        // presenting the build id as if it were the version.
        #expect(HomebrewRowCell.shortVersion(",123") == ",123")
        // Only the first comma splits, so a build id containing one survives intact.
        #expect(HomebrewRowCell.shortVersion("1.0,a,b") == "1.0")
    }
}
