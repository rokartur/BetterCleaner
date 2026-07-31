import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewSecurityScanTests {
    @Test func queriesSkipCasksAndStripRevisionSuffix() throws {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.infoJSON.utf8))
        let packages = info.formulae.map(HomebrewPackage.init(formula:))
            + info.casks.map(HomebrewPackage.init(cask:))

        let queries = HomebrewSecurityScan.queries(for: packages)

        // The cask and the uninstalled (version-less) formula are dropped.
        #expect(queries == [
            .init(package: .init(name: "wget"), version: "1.24.5"),
            .init(package: .init(name: "openssl"), version: "3.3.1"),
        ])
    }

    @Test func versionNormalization() {
        #expect(HomebrewSecurityScan.normalizedVersion("1.24.5_1") == "1.24.5")
        #expect(HomebrewSecurityScan.normalizedVersion("1.24.5") == "1.24.5")
        // Not a brew revision — underscore segment isn't numeric, or nothing precedes it.
        #expect(HomebrewSecurityScan.normalizedVersion("2024_beta") == "2024_beta")
        #expect(HomebrewSecurityScan.normalizedVersion("_1") == "_1")
    }

    @Test func findingsPairPositionallyAndKeepOnlyHits() throws {
        let queries = [
            HomebrewSecurityScan.Query(package: .init(name: "wget"), version: "1.24.5"),
            HomebrewSecurityScan.Query(package: .init(name: "openssl"), version: "3.3.1"),
        ]
        let response = try JSONDecoder().decode(
            HomebrewSecurityScan.BatchResponse.self,
            from: Data(Self.responseJSON.utf8)
        )

        let findings = HomebrewSecurityScan.findings(queries: queries, results: response.results)

        #expect(findings == [
            .init(package: "openssl", version: "3.3.1",
                  vulnerabilityIDs: ["CVE-2024-0001", "GHSA-xxxx-yyyy-zzzz"]),
        ])
        #expect(HomebrewSecurityScan.advisoryURL("CVE-2024-0001")
            == "https://osv.dev/vulnerability/CVE-2024-0001")
    }

    private static let infoJSON = """
    {
      "formulae": [
        {
          "name": "wget", "full_name": "wget", "versions": { "stable": "1.25.0" },
          "installed": [{ "version": "1.24.5", "installed_on_request": true }],
          "outdated": false, "pinned": false
        },
        {
          "name": "openssl", "full_name": "openssl", "versions": { "stable": "3.3.1" },
          "installed": [{ "version": "3.3.1_1", "installed_on_request": false }],
          "outdated": false, "pinned": false
        },
        {
          "name": "ghost", "full_name": "ghost", "versions": { "stable": "1.0" },
          "installed": [], "outdated": false, "pinned": false
        }
      ],
      "casks": [{
        "token": "firefox", "name": ["Firefox"], "version": "120.0",
        "installed": "120.0", "outdated": false, "pinned": false
      }]
    }
    """

    private static let responseJSON = """
    {
      "results": [
        {},
        { "vulns": [
          { "id": "CVE-2024-0001", "modified": "2024-01-01T00:00:00Z" },
          { "id": "GHSA-xxxx-yyyy-zzzz", "modified": "2024-01-02T00:00:00Z" }
        ]}
      ]
    }
    """
}
