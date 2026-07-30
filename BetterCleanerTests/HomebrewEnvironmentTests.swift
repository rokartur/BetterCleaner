import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewEnvironmentTests {
    @Test func resolvesUserPathBeforeStandardFallback() {
        let executable = Set(["/opt/homebrew/bin/brew", "/custom/bin/brew"])
        let path = HomebrewEnvironment.resolveBrewPath(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            standardCandidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            isExecutable: { executable.contains($0) }
        )
        #expect(path == "/custom/bin/brew")
    }

    @Test func resolvesCustomPrefixAndPath() {
        let prefixPath = HomebrewEnvironment.resolveBrewPath(
            environment: ["HOMEBREW_PREFIX": "/custom", "PATH": "/other/bin"],
            standardCandidates: [],
            isExecutable: { $0 == "/custom/bin/brew" }
        )
        let pathPath = HomebrewEnvironment.resolveBrewPath(
            environment: ["PATH": "/other/bin:/usr/bin"],
            standardCandidates: [],
            isExecutable: { $0 == "/other/bin/brew" }
        )
        #expect(prefixPath == "/custom/bin/brew")
        #expect(pathPath == "/other/bin/brew")
    }

    @Test func preservesUserEnvironmentAndAddsTrustedAskpass() {
        let environment = HomebrewEnvironment.environment(
            base: [
                "HOME": "/Users/test",
                "PATH": "/custom/tools:/usr/bin",
                "HTTPS_PROXY": "http://proxy.example",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
                "SUDO_ASKPASS": "/untrusted/helper",
            ],
            brewPath: "/custom/homebrew/bin/brew",
            askpassPath: "/Applications/BetterCleaner.app/Contents/Resources/homebrew-sudo-askpass"
        )

        #expect(environment["HTTPS_PROXY"] == "http://proxy.example")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(environment["SUDO_ASKPASS"]?.hasSuffix("homebrew-sudo-askpass") == true)
        #expect(environment["HOMEBREW_NO_ASK"] == "1")
        #expect(environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(environment["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] == "1")
        #expect(environment["PATH"]?.hasPrefix("/custom/homebrew/bin:/custom/homebrew/sbin:") == true)
        #expect(environment["PATH"]?.contains("/custom/tools") == true)
    }

    @Test func bundledAskpassIsExecutable() throws {
        let path = try #require(HomebrewEnvironment.askpassPath)
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }
}
