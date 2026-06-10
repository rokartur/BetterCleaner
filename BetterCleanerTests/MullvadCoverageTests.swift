import Testing
import Foundation
@testable import BetterCleaner

/// Regression coverage for the Mullvad VPN footprint — a VPN that scatters files
/// a Library-only scan misses: a root daemon, CLI binaries + shell-completion
/// scripts under /usr/local & /opt/homebrew, a team-prefixed cache folder, and
/// /etc + /var/log daemon data. Every path from Mullvad's own uninstall_macos.sh
/// must be attributable to the app so BetterCleaner removes at least as much as
/// other cleaners. Production runs at `.aggressive`.
@Suite struct MullvadCoverageTests {
    private let mullvad = AppDescriptor(
        bundleID: "net.mullvad.vpn", name: "Mullvad VPN", executable: "Mullvad VPN")

    @Test func bundleIDAndTeamPrefixedCacheAreStrong() {
        #expect(FileMatcher.match(fileName: "net.mullvad.vpn", descriptor: mullvad, sensitivity: .aggressive) == .strong)
        #expect(FileMatcher.match(fileName: "net.mullvad.vpn.plist", descriptor: mullvad, sensitivity: .aggressive) == .strong)
        // ~/Library/Caches/6ca58e31.net.mullvad.vpn — bundle id as a bounded token.
        #expect(FileMatcher.match(fileName: "6ca58e31.net.mullvad.vpn", descriptor: mullvad, sensitivity: .aggressive) == .strong)
    }

    @Test func displayNameFoldersAreStrong() {
        // /Library/Caches/mullvad-vpn, ~/Library/Application Support/Mullvad VPN,
        // /etc/mullvad-vpn, /var/log/mullvad-vpn — all normalize to "mullvadvpn".
        #expect(FileMatcher.match(fileName: "mullvad-vpn", descriptor: mullvad, sensitivity: .aggressive) == .strong)
        #expect(FileMatcher.match(fileName: "Mullvad VPN", descriptor: mullvad, sensitivity: .aggressive) == .strong)
    }

    @Test func daemonCliAndCompletionsAreAttributed() {
        // The leftovers a Library-only scan would miss — must at least be surfaced
        // (weak); auto-selection happens when the "mullvad" vendor is exclusive.
        for name in [
            "net.mullvad.daemon.plist",      // /Library/LaunchDaemons
            "mullvad",                        // /usr/local/bin/mullvad
            "mullvad-problem-report",         // /usr/local/bin/mullvad-problem-report
            "_mullvad",                       // /usr/local/share/zsh/site-functions/_mullvad
            "mullvad.fish",                   // .../fish/vendor_completions.d/mullvad.fish
        ] {
            #expect(FileMatcher.match(fileName: name, descriptor: mullvad, sensitivity: .aggressive) != nil,
                    "expected a match for \(name)")
        }
    }

    @Test func unrelatedSystemFilesNeverMatch() {
        // The new /usr/local, /etc and /var/log scans must not sweep unrelated tools.
        for name in ["spotify", "com.apple.dock", "hosts", "system.log", "_git", "node.fish"] {
            #expect(FileMatcher.match(fileName: name, descriptor: mullvad, sensitivity: .aggressive) == nil,
                    "did not expect a match for \(name)")
        }
    }

    @Test func newScanDirsAreCataloged() {
        // Unix tool + completion categories and the /etc + /var/log categories must
        // be in categoryOrder so their results aren't dumped at the bottom.
        let order = Set(Locations.categoryOrder)
        for category in ["Command Line Tools", "Shell Completions", "Configuration", "Logs"] {
            #expect(order.contains(category))
        }
    }
}
