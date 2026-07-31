import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewServiceTests {
    @Test func filtersVirtualUninstalledTaps() throws {
        let taps = try HomebrewService.parseTaps(Self.tapsJSON)
        #expect(taps.map(\.name) == ["user/tools"])
    }

    @Test func commandFailureKeepsStatusAndMessage() {
        let output = CommandRunner.Output(status: 7, stdout: "", stderr: "network unavailable\n")
        do {
            _ = try HomebrewService.checked(output, arguments: ["search", "wget"])
            Issue.record("Expected command failure")
        } catch let error as HomebrewServiceError {
            #expect(error == .commandFailed(arguments: ["search", "wget"], status: 7,
                                             message: "network unavailable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func malformedJSONIsAnError() {
        #expect(throws: HomebrewServiceError.self) {
            _ = try HomebrewService.parseTaps("not json")
        }
    }

    @Test func descriptionSearchPreservesPackageKind() {
        let results = HomebrewService.parseDescriptionSearch("""
        ==> Formulae
        wget: Internet file retriever
        ==> Casks
        firefox: Web browser: stable channel
        """)
        #expect(results[HomebrewPackageRef(token: "wget", kind: .formula)] == "Internet file retriever")
        #expect(results[HomebrewPackageRef(token: "firefox", kind: .cask)] == "Web browser: stable channel")
    }

    @Test func greedyOutdatedUsesActualCaskBundleVersion() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.infoJSON.utf8))
        let outdated = try JSONDecoder().decode(BrewOutdatedV2.self, from: Data(Self.outdatedJSON.utf8))
        let source = info.formulae.map(HomebrewPackage.init(formula:))
            + info.casks.map(HomebrewPackage.init(cask:))

        let merged = HomebrewService.mergeOutdated(source, outdated: outdated) { package in
            package.isCask ? ("1.2.94.583", nil) : nil
        }
        let formula = try #require(merged.first { !$0.isCask })
        let cask = try #require(merged.first(where: { $0.isCask }))
        #expect(formula.isOutdated)
        #expect(formula.isPinned)
        #expect(cask.installedVersion == "1.2.94.583")
        #expect(!cask.isOutdated)

        let oldBundle = HomebrewService.mergeOutdated(source, outdated: outdated) { package in
            package.isCask ? ("1.2.93", nil) : nil
        }
        #expect(oldBundle.first(where: { $0.isCask })?.isOutdated == true)

        let incompleteBundle = HomebrewService.mergeOutdated(source, outdated: outdated) { package in
            package.isCask ? ("1.2", nil) : nil
        }
        #expect(incompleteBundle.first(where: { $0.isCask })?.installedVersion == "1.2.92.148")
    }

    @Test func outdatedMatchesExternalTapFullName() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.infoJSON.utf8))
        let outdated = try JSONDecoder().decode(BrewOutdatedV2.self, from: Data(Self.outdatedJSON.utf8))
        let formula = try #require(info.formulae.first.map(HomebrewPackage.init(formula:)))

        let merged = HomebrewService.mergeOutdated([formula], outdated: outdated)

        #expect(formula.commandToken == "user/tools/wget")
        #expect(merged.first?.isOutdated == true)
    }

    @Test func latestCaskDoesNotCreateSyntheticUpdate() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.infoJSON.utf8))
        let cask = try #require(info.casks.first.map(HomebrewPackage.init(cask:)))
        let outdated = BrewOutdatedV2(formulae: [], casks: [
            .init(name: "spotify", fullName: nil, installedVersions: ["1.2.92.148"],
                  currentVersion: "latest", pinned: false),
        ])

        let merged = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in nil }

        #expect(merged.first?.latestVersion == "latest")
        #expect(merged.first?.isOutdated == false)
    }

    @Test func equalCaskVersionUsesBundleBuildAsTieBreaker() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.infoJSON.utf8))
        let cask = try #require(info.casks.first.map(HomebrewPackage.init(cask:)))
        let outdated = try JSONDecoder().decode(BrewOutdatedV2.self, from: Data(Self.outdatedJSON.utf8))

        let olderBuild = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in
            ("1.2.94.583", "100")
        }
        let newerBuild = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in
            ("1.2.94.583", "400")
        }

        #expect(cask.latestBundleVersion == "345")
        #expect(olderBuild.first?.isOutdated == true)
        #expect(newerBuild.first?.isOutdated == false)
    }

    @Test func commaVersionSuppliesMissingCaskBundleBuild() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.commaCaskInfoJSON.utf8))
        let cask = try #require(info.casks.first.map(HomebrewPackage.init(cask:)))
        let outdated = BrewOutdatedV2(formulae: [], casks: [
            .init(name: "alfred", fullName: nil, installedVersions: ["5.7.3,2200"],
                  currentVersion: "5.7.3,2320", pinned: false),
        ])

        let oldBuild = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in
            ("5.7.3", "2200")
        }
        let newerBuild = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in
            ("5.7.3", "2400")
        }
        let incompleteShortVersion = HomebrewService.mergeOutdated([cask], outdated: outdated) { _ in
            ("5.7", "2200")
        }

        #expect(cask.latestBundleVersion.isEmpty)
        #expect(oldBuild.first?.isOutdated == true)
        #expect(newerBuild.first?.isOutdated == false)
        #expect(incompleteShortVersion.first?.isOutdated == true)
    }

    @Test func recognizesBrewSearchNoResultsErrorPrefix() {
        #expect(HomebrewService.isNoSearchResults("Error: No formulae or casks found for foo."))
    }

    @Test func flagLikeSearchQueriesNeverReachBrew() throws {
        // Would otherwise be parsed as brew flags (worst case `--eval-all`).
        #expect(try HomebrewService.search("--eval-all", kind: .formula).isEmpty)
        #expect(try HomebrewService.search("  -f", kind: .cask).isEmpty)
        #expect(try HomebrewService.searchWithDescriptions("-desc").isEmpty)
    }

    private static let tapsJSON = """
    [
      {
        "name": "homebrew/core",
        "installed": false,
        "official": true,
        "formula_names": ["wget"],
        "cask_tokens": []
      },
      {
        "name": "user/tools",
        "installed": true,
        "official": false,
        "formula_names": ["user/tools/widget"],
        "cask_tokens": []
      }
    ]
    """

    private static let infoJSON = """
    {
      "formulae": [{
        "name": "wget", "full_name": "user/tools/wget", "versions": { "stable": "1.25.0" },
        "installed": [{ "version": "1.24.5", "installed_on_request": true }],
        "outdated": false, "pinned": false
      }],
      "casks": [{
        "token": "spotify", "name": ["Spotify"], "version": "1.2.94.583", "bundle_version": "345",
        "installed": "1.2.92.148", "outdated": true, "pinned": false,
        "artifacts": [{ "app": ["Spotify.app"], "target": "/Applications/Spotify.app" }]
      }]
    }
    """

    private static let outdatedJSON = """
    {
      "formulae": [{
        "name": "wget", "full_name": "user/tools/wget", "installed_versions": ["1.24.5"],
        "current_version": "1.25.0", "pinned": true
      }],
      "casks": [{
        "name": "spotify", "installed_versions": ["1.2.92.148"],
        "current_version": "1.2.94.583", "pinned": false
      }]
    }
    """

    private static let commaCaskInfoJSON = """
    {
      "formulae": [],
      "casks": [{
        "token": "alfred", "name": ["Alfred"], "version": "5.7.3,2320",
        "installed": "5.7.3,2200", "outdated": true, "pinned": false,
        "artifacts": [{ "app": ["Alfred 5.app"], "target": "/Applications/Alfred 5.app" }]
      }]
    }
    """
}
