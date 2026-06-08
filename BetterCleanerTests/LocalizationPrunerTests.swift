import Testing
@testable import BetterCleaner

@Suite struct LocalizationPrunerTests {
    private let keep: Set<String> = ["base", "en", "english", "pl", "fr"]

    @Test func keepsBaseEnglishAndPreferred() {
        #expect(LocalizationPruner.shouldKeep(lprojName: "Base.lproj", keep: keep))
        #expect(LocalizationPruner.shouldKeep(lprojName: "en.lproj", keep: keep))
        #expect(LocalizationPruner.shouldKeep(lprojName: "English.lproj", keep: keep))
        #expect(LocalizationPruner.shouldKeep(lprojName: "pl.lproj", keep: keep))
    }

    @Test func prunesUnlistedLanguages() {
        #expect(!LocalizationPruner.shouldKeep(lprojName: "de.lproj", keep: keep))
        #expect(!LocalizationPruner.shouldKeep(lprojName: "ja.lproj", keep: keep))
    }

    @Test func regionalVariantFallsBackToBaseCode() {
        // "en-GB"/"zh-Hans" keep decision uses the base code.
        #expect(LocalizationPruner.shouldKeep(lprojName: "en-GB.lproj", keep: keep))
        #expect(LocalizationPruner.shouldKeep(lprojName: "fr_CA.lproj", keep: keep))
        #expect(!LocalizationPruner.shouldKeep(lprojName: "zh-Hans.lproj", keep: keep))
    }

    @Test func keepCodesIncludesEnglishAndBase() {
        let codes = LocalizationPruner.keepCodes()
        #expect(codes.contains("en"))
        #expect(codes.contains("base"))
    }
}
