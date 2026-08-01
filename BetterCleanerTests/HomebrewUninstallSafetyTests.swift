import Testing
@testable import BetterCleaner

@Suite struct HomebrewUninstallSafetyTests {
    @Test func loadingFailsClosed() {
        let check = HomebrewDependentsCheck.loading

        #expect(!check.canUninstall)
        #expect(check.requiresConfirmation(confirmBeforeDelete: false, zap: false))
    }

    @Test func failedLookupRequiresConfirmation() {
        let check = HomebrewDependentsCheck.failed("brew uses failed")

        #expect(check.canUninstall)
        #expect(check.failureMessage == "brew uses failed")
        #expect(check.requiresConfirmation(confirmBeforeDelete: false, zap: false))
    }

    @Test func knownDependentsRequireConfirmation() {
        let check = HomebrewDependentsCheck.loaded(["php", "wget"])

        #expect(check.canUninstall)
        #expect(check.requiresConfirmation(confirmBeforeDelete: false, zap: false))
        #expect(check.dependents == ["php", "wget"])
    }

    @Test func verifiedEmptyResultHonorsPreference() {
        let check = HomebrewDependentsCheck.loaded([])

        #expect(check.canUninstall)
        #expect(!check.requiresConfirmation(confirmBeforeDelete: false, zap: false))
        #expect(check.requiresConfirmation(confirmBeforeDelete: true, zap: false))
    }

    @Test func zapAlwaysRequiresConfirmation() {
        let check = HomebrewDependentsCheck.notNeeded

        #expect(check.canUninstall)
        #expect(!check.requiresConfirmation(confirmBeforeDelete: false, zap: false))
        #expect(check.requiresConfirmation(confirmBeforeDelete: false, zap: true))
    }
}
