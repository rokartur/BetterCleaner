import Testing
import Foundation
@testable import BetterCleaner

@Suite struct JunkScannerTests {
    // JunkScanner.scan() deep-walks the real ~/Library (caches, DerivedData, …),
    // which is unbounded on a developer machine — not unit-testable without a
    // fixture filesystem. Per the project convention (tests cover pure logic, no
    // real-FS walks), we assert the catalog/order wiring only.

    @Test func locationOrderIncludesNewCrashAndAutosaveCategories() {
        #expect(Locations.categoryOrder.contains("Crash Reports"))
        #expect(Locations.categoryOrder.contains("Autosave Information"))
    }

    @Test func locationOrderHasNoDuplicates() {
        let order = Locations.categoryOrder
        #expect(Set(order).count == order.count)
    }
}
