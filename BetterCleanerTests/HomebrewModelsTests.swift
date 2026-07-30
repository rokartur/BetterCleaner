import Testing
import Foundation
@testable import BetterCleaner

@Suite struct HomebrewModelsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func decodesInfoV2AndMapsFormula() throws {
        let info = try decode(BrewInfoV2.self, Self.infoJSON)
        #expect(info.formulae.count == 1)
        let wget = HomebrewPackage(formula: info.formulae[0])
        #expect(wget.token == "wget")
        #expect(wget.commandToken == "user/tools/wget")
        #expect(wget.displayName == "wget")
        #expect(wget.installedVersion == "1.24.5")
        #expect(wget.latestVersion == "1.25.0")
        #expect(wget.isOutdated)
        #expect(wget.installedOnRequest)
        #expect(wget.dependencies == ["libidn2", "openssl@3"])
        #expect(wget.tap == "homebrew/core")
        #expect(wget.license == "GPL-3.0-or-later")
        #expect(wget.caveats == "Restart your shell.")
        #expect(wget.requirements == ["macos >= 13"])
        #expect(wget.hasService)
        #expect(!wget.isCask)
    }

    @Test func decodesInfoV2AndMapsCask() throws {
        let info = try decode(BrewInfoV2.self, Self.infoJSON)
        #expect(info.casks.count == 1)
        let firefox = HomebrewPackage(cask: info.casks[0])
        #expect(firefox.token == "firefox")
        #expect(firefox.commandToken == "user/apps/firefox")
        #expect(firefox.displayName == "Firefox")   // human name, not the token
        #expect(firefox.installedVersion == "119.0")
        #expect(firefox.latestVersion == "120.0")
        #expect(firefox.isOutdated)
        #expect(firefox.autoUpdates)
        #expect(firefox.isPinned)
        #expect(firefox.dependencies == ["openssl@3"])
        #expect(firefox.appArtifacts.map(\.bundleName) == ["Firefox.app"])
        #expect(firefox.actualAppURLs.map(\.path) == ["/Applications/Firefox.app"])
        #expect(firefox.requirements == ["macOS >= 13"])
        #expect(!firefox.isDeprecated)
        #expect(!firefox.isDisabled)
        #expect(firefox.isCask)
    }

    @Test func decodesServices() throws {
        let services = try decode([ServiceInfo].self, Self.servicesJSON)
        #expect(services.count == 2)
        #expect(services[0].name == "php")
        #expect(services[0].isRunning)
        #expect(!services[1].isRunning)        // stopped
    }

    @Test func decodesTaps() throws {
        let taps = try decode([TapInfo].self, Self.tapsJSON)
        #expect(taps.count == 1)
        #expect(taps[0].name == "homebrew/cask")
        #expect(taps[0].installed)
        #expect(taps[0].official == true)
        #expect(taps[0].packageCount == 2)      // 0 formulae + 2 casks
        #expect(taps[0].packageRefs == [
            HomebrewPackageRef(token: "firefox", kind: .cask),
            HomebrewPackageRef(token: "iterm2", kind: .cask),
        ])
    }

    @Test func packageKindRoundTripsThroughCodable() throws {
        let encoded = try JSONEncoder().encode(HomebrewPackage.Kind.cask)
        #expect(try JSONDecoder().decode(HomebrewPackage.Kind.self, from: encoded) == .cask)
    }

    // MARK: - Fixtures

    private static let infoJSON = """
    {
      "formulae": [
        {
          "name": "wget",
          "full_name": "user/tools/wget",
          "desc": "Internet file retriever",
          "homepage": "https://www.gnu.org/software/wget/",
          "versions": { "stable": "1.25.0" },
          "installed": [
            { "version": "1.24.5", "installed_as_dependency": false, "installed_on_request": true }
          ],
          "outdated": true,
          "pinned": false,
          "dependencies": ["libidn2", "openssl@3"],
          "tap": "homebrew/core",
          "caveats": "Restart your shell.",
          "license": "GPL-3.0-or-later",
          "deprecated": false,
          "deprecation_reason": null,
          "disabled": false,
          "disable_reason": null,
          "requirements": [{ "name": "macos", "version": ">= 13" }],
          "service": { "run": ["wget", "--serve"] }
        }
      ],
      "casks": [
        {
          "token": "firefox",
          "full_token": "user/apps/firefox",
          "tap": "homebrew/cask",
          "name": ["Firefox"],
          "desc": "Web browser",
          "homepage": "https://www.mozilla.org/firefox/",
          "version": "120.0",
          "installed": "119.0",
          "outdated": true,
          "pinned": true,
          "auto_updates": true,
          "depends_on": { "formula": ["openssl@3"], "macos": { ">=": ["13"] } },
          "artifacts": [{ "app": ["Firefox.app"], "target": "/Applications/Firefox.app" }],
          "caveats": "Close Firefox first.",
          "license": "MPL-2.0",
          "deprecated": false,
          "deprecation_reason": null,
          "disabled": false,
          "disable_reason": null
        }
      ]
    }
    """

    private static let servicesJSON = """
    [
      { "name": "php", "status": "started", "user": "tester", "file": "/opt/homebrew/Cellar/php/php.plist" },
      { "name": "dnsmasq", "status": "stopped", "user": null, "file": null }
    ]
    """

    private static let tapsJSON = """
    [
      {
        "name": "homebrew/cask",
        "installed": true,
        "user": "Homebrew",
        "repo": "cask",
        "official": true,
        "remote": "https://github.com/Homebrew/homebrew-cask",
        "formula_names": [],
        "cask_tokens": ["firefox", "iterm2"]
      }
    ]
    """
}
