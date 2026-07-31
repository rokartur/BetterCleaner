import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewMaintenanceTests {
    @Test func parsesVersionFromBrewBanner() {
        let output = """
        Homebrew 4.10.2-15-gabcdef
        Homebrew/homebrew-core (git revision 1234; last commit 2026-07-30)
        """

        #expect(HomebrewMaintenance.parseCurrentVersion(output) == "4.10.2-15-gabcdef")
        #expect(HomebrewMaintenance.parseCurrentVersion("unexpected output") == nil)
    }

    @Test func decodesLatestStableGitHubRelease() throws {
        let data = Data(#"{"tag_name":"v4.10.3"}"#.utf8)
        #expect(try HomebrewMaintenance.parseLatestVersion(data) == "4.10.3")
    }

    @Test func rejectsUnreadableGitHubRelease() {
        #expect(throws: HomebrewMaintenanceError.self) {
            _ = try HomebrewMaintenance.parseLatestVersion(Data(#"{"name":"Homebrew"}"#.utf8))
        }
    }

    @Test func comparesVersionsNumerically() {
        #expect(HomebrewMaintenance.isUpdateAvailable(current: "4.9.9", latest: "4.10.0"))
        #expect(!HomebrewMaintenance.isUpdateAvailable(current: "4.10.0", latest: "4.10.0"))
        #expect(!HomebrewMaintenance.isUpdateAvailable(current: "4.11.0", latest: "4.10.0"))
    }

    @Test func parsesModernAnalyticsMessages() {
        #expect(HomebrewMaintenance.parseAnalyticsState(
            "InfluxDB analytics are enabled. Google Analytics were destroyed."
        ) == true)
        #expect(HomebrewMaintenance.parseAnalyticsState("InfluxDB analytics are disabled.") == false)
        #expect(HomebrewMaintenance.parseAnalyticsState("No analytics preference was returned.") == nil)
    }

    @Test func doctorReportKeepsExitStatusAndBothOutputStreams() {
        let output = CommandRunner.Output(
            status: 1,
            stdout: "Warning: first finding\n",
            stderr: "Error: second finding\n"
        )

        let report = HomebrewMaintenance.doctorReport(from: output)
        #expect(report.exitStatus == 1)
        #expect(report.output == "Warning: first finding\nError: second finding\n")
        #expect(!report.isHealthy)
    }

    @Test func parsesAndExpandsCachePath() {
        let url = HomebrewMaintenance.parseCacheURL("  ~/Library/Caches/Homebrew\n")
        #expect(url?.path == (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/Homebrew"))
    }
}
