import Testing
import Foundation
@testable import BetterCleaner

@Suite struct HomebrewActionsTests {
    // A formula + a cask decoded once for the package-shaped builders.
    private func packages() throws -> (formula: HomebrewPackage, cask: HomebrewPackage) {
        let info = try JSONDecoder().decode(BrewInfoV2.self, from: Data(Self.json.utf8))
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
        #expect(HomebrewActions.upgradeArgs(cask) == ["upgrade", "--cask", "firefox"])
    }

    @Test func upgradeAllArgs() {
        #expect(HomebrewActions.upgradeAllArgs(greedy: false) == ["upgrade"])
        #expect(HomebrewActions.upgradeAllArgs(greedy: true) == ["upgrade", "--greedy"])
    }

    @Test func installArgs() {
        #expect(HomebrewActions.installArgs(token: "wget", isCask: false) == ["install", "wget"])
        #expect(HomebrewActions.installArgs(token: "firefox", isCask: true) == ["install", "--cask", "firefox"])
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
        #expect(HomebrewActions.tapArgs("user/repo") == ["tap", "user/repo"])
        #expect(HomebrewActions.untapArgs("user/repo") == ["untap", "user/repo"])
    }

    @Test func maintenanceArgs() {
        #expect(HomebrewActions.updateArgs() == ["update"])
        #expect(HomebrewActions.cleanupArgs() == ["cleanup", "-s"])
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
          "homepage": "", "version": "120.0", "installed": "120.0", "outdated": false
        }
      ]
    }
    """
}
