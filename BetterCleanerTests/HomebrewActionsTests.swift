import Testing
import Foundation
@testable import BetterCleaner

@Suite struct HomebrewActionsTests {
    // A formula + a cask decoded once for the package-shaped builders.
    private func packages(pinned: Bool = false) throws -> (formula: HomebrewPackage, cask: HomebrewPackage) {
        let json = pinned
            ? Self.json.replacingOccurrences(of: "\"pinned\": false", with: "\"pinned\": true")
            : Self.json
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(json.utf8))
        return (HomebrewPackage(formula: info.formulae[0]), HomebrewPackage(cask: info.casks[0]))
    }

    @Test func uninstallFormulaIgnoresZap() throws {
        let (formula, _) = try packages()
        #expect(HomebrewActions.uninstallArgs(formula, zap: false) == ["uninstall", "wget"])
        // zap is cask-only — never added for a formula.
        #expect(HomebrewActions.uninstallArgs(formula, zap: true) == ["uninstall", "wget"])
    }

    @Test func uninstallCaskWithAndWithoutZap() throws {
        let (_, cask) = try packages()
        #expect(HomebrewActions.uninstallArgs(cask, zap: false) == ["uninstall", "--cask", "firefox"])
        #expect(HomebrewActions.uninstallArgs(cask, zap: true) == ["uninstall", "--cask", "--zap", "firefox"])
    }

    @Test func upgradeArgs() throws {
        let (formula, cask) = try packages()
        #expect(HomebrewActions.upgradeArgs(formula) == ["upgrade", "wget"])
        // --greedy must match the `outdated --greedy` detection, or auto-updating
        // casks we just flagged as outdated would be silently skipped by brew.
        #expect(HomebrewActions.upgradeArgs(cask) == ["upgrade", "--cask", "--greedy", "firefox"])
    }

    @Test func upgradePlanUsesOneRequiredStepForUnpinnedPackages() throws {
        let (formula, cask) = try packages()
        #expect(HomebrewActions.upgradePlan(formula).steps == [.required(["upgrade", "wget"])])
        #expect(HomebrewActions.upgradePlan(cask).steps == [.required(["upgrade", "--cask", "--greedy", "firefox"])])
    }

    @Test func upgradePlanAlwaysRepinsPinnedPackages() throws {
        let (formula, cask) = try packages(pinned: true)
        #expect(HomebrewActions.upgradePlan(formula).steps == [
            .required(["unpin", "--formula", "wget"]),
            .required(["upgrade", "wget"]),
            .finally(["pin", "--formula", "wget"]),
        ])
        #expect(HomebrewActions.upgradePlan(cask).steps == [
            .required(["unpin", "--cask", "firefox"]),
            .required(["upgrade", "--cask", "--greedy", "firefox"]),
            .finally(["pin", "--cask", "firefox"]),
        ])
    }

    @Test func installArgs() {
        #expect(HomebrewActions.installArgs(HomebrewPackageRef(token: "wget", kind: .formula)) == ["install", "wget"])
        #expect(HomebrewActions.installArgs(HomebrewPackageRef(token: "firefox", kind: .cask)) == ["install", "--cask", "firefox"])
    }

    @Test func mutationsUseUnambiguousTapToken() throws {
        let cask = try caskPackage()
        #expect(HomebrewActions.upgradeArgs(cask) == ["upgrade", "--cask", "--greedy", "custom/tools/visual-studio-code"])
        #expect(HomebrewActions.uninstallArgs(cask, zap: false) == ["uninstall", "--cask", "custom/tools/visual-studio-code"])
        #expect(HomebrewActions.pinArgs(cask) == ["pin", "--cask", "custom/tools/visual-studio-code"])
    }

    @Test func adoptArgs() {
        #expect(HomebrewActions.adoptArgs(tokens: ["slack", "zoom"]) == ["install", "--cask", "--adopt", "slack", "zoom"])
    }

    @Test func serviceArgs() {
        #expect(HomebrewActions.serviceArgs(.start, name: "php") == ["services", "start", "php"])
        #expect(HomebrewActions.serviceArgs(.stop, name: "php") == ["services", "stop", "php"])
        #expect(HomebrewActions.serviceArgs(.restart, name: "php") == ["services", "restart", "php"])
    }

    @Test func tapArgs() {
        #expect(HomebrewActions.validTapName(" user/repo ") == "user/repo")
        #expect(HomebrewActions.validTapName("user/homebrew-tools") == "user/homebrew-tools")
        #expect(HomebrewActions.validTapName("--force") == nil)
        #expect(HomebrewActions.validTapName("https://example.com/tap") == nil)
        #expect(HomebrewActions.tapArgs("user/repo") == ["tap", "user/repo"])
        #expect(HomebrewActions.untapArgs("user/repo") == ["untap", "user/repo"])
        #expect(!HomebrewActions.untapArgs("user/repo").contains("--force"))
    }

    @Test func maintenanceArgs() {
        #expect(HomebrewActions.updateArgs() == ["update"])
        #expect(HomebrewActions.cleanupArgs() == ["cleanup", "-s"])
        #expect(HomebrewActions.cleanupArgs(dryRun: true) == ["cleanup", "-s", "--dry-run"])
        #expect(HomebrewActions.autoremoveArgs() == ["autoremove"])
        #expect(HomebrewActions.bundleDumpArgs(file: "/tmp/Brewfile") == ["bundle", "dump", "--describe", "--force", "--file", "/tmp/Brewfile"])
        #expect(HomebrewActions.bundleInstallArgs(file: "/tmp/Brewfile") == ["bundle", "install", "--file", "/tmp/Brewfile"])
    }

    @Test func adopterSlug() {
        #expect(HomebrewAdopter.slug("Visual Studio Code") == "visual-studio-code")
        #expect(HomebrewAdopter.slug("iTerm2") == "iterm2")
        #expect(HomebrewAdopter.slug("Google Chrome") == "google-chrome")
        #expect(HomebrewAdopter.slug("  Spaced  Name  ") == "spaced-name")
    }

    @Test func adopterRequiresExactArtifactAndTracksVersionCompatibility() throws {
        let app = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            bundleID: "com.microsoft.VSCode",
            name: "Microsoft Visual Studio Code",
            isSystem: false,
            shortVersion: "1.2.3"
        )
        let exact = try caskPackage(version: "1.2.3")
        #expect(HomebrewAdopter.match(app: app, package: exact)?.versionCompatible == true)
        #expect(HomebrewAdopter.candidates(apps: [app], installedPackages: [exact]).isEmpty)
        #expect(HomebrewAdopter.candidates(apps: [app], installedPackages: []).count == 1)

        let sameBundleInUserApplications = InstalledApp(
            url: URL(fileURLWithPath: "/Users/test/Applications/Visual Studio Code.app"),
            bundleID: app.bundleID,
            name: app.name,
            isSystem: false,
            shortVersion: app.shortVersion
        )
        #expect(HomebrewAdopter.match(app: sameBundleInUserApplications, package: exact) == nil)
        #expect(HomebrewAdopter.candidates(apps: [sameBundleInUserApplications], installedPackages: [exact]).count == 1)

        let caskWithoutArtifacts = try packages().cask
        let sameDisplayName = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Firefox.app"),
            bundleID: "org.mozilla.firefox",
            name: "Firefox",
            isSystem: false,
            shortVersion: "120.0"
        )
        #expect(HomebrewAdopter.candidates(apps: [sameDisplayName], installedPackages: [caskWithoutArtifacts]).count == 1)

        let similarApp = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Visual Studio Code Insiders.app"),
            bundleID: nil,
            name: "Visual Studio Code Insiders",
            isSystem: false,
            shortVersion: "1.2.3"
        )
        #expect(HomebrewAdopter.match(app: similarApp, package: exact) == nil)
        #expect(HomebrewAdopter.match(app: app, package: try caskPackage(version: "2.0"))?.versionCompatible == false)
        #expect(HomebrewAdopter.match(app: app, package: try caskPackage(version: "2.0", autoUpdates: true))?.versionCompatible == true)
        #expect(HomebrewAdopter.match(app: app, package: try caskPackage(deprecated: true)) == nil)
        #expect(HomebrewAdopter.match(app: app, package: try caskPackage(disabled: true)) == nil)
    }

    private func caskPackage(version: String = "1.2.3", autoUpdates: Bool = false,
                             deprecated: Bool = false, disabled: Bool = false) throws -> HomebrewPackage {
        let json = """
        {
          "formulae": [],
          "casks": [{
            "token": "visual-studio-code",
            "full_token": "custom/tools/visual-studio-code",
            "tap": "custom/tools",
            "name": ["Microsoft Visual Studio Code"],
            "version": "\(version)",
            "installed": null,
            "outdated": false,
            "pinned": false,
            "auto_updates": \(autoUpdates),
            "artifacts": [{
              "app": ["Visual Studio Code.app"],
              "target": "/Applications/Visual Studio Code.app"
            }],
            "deprecated": \(deprecated),
            "disabled": \(disabled)
          }]
        }
        """
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(json.utf8))
        return HomebrewPackage(cask: info.casks[0])
    }

    private static let json = """
    {
      "formulae": [
        {
          "name": "wget", "full_name": "wget", "desc": "", "homepage": "",
          "versions": { "stable": "1.25.0" },
          "installed": [{ "version": "1.24.5", "installed_on_request": true }],
          "outdated": false, "pinned": false, "dependencies": [], "tap": "homebrew/core"
        }
      ],
      "casks": [
        {
          "token": "firefox", "tap": "homebrew/cask", "name": ["Firefox"], "desc": "",
          "homepage": "", "version": "120.0", "installed": "120.0", "outdated": false, "pinned": false
        }
      ]
    }
    """
}
