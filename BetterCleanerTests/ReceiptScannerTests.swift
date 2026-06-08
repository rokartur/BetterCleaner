import Testing
import Foundation
@testable import BetterCleaner

@Suite struct ReceiptScannerTests {
    private let descriptor = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar", extraBundleIDs: ["com.foo.Helper"])

    @Test func matchesExactChildAndParentAndNested() {
        let ids = ["com.foo.Bar", "com.foo.Bar.pkg", "com.foo", "com.foo.Helper", "com.other.Thing", "com.foobar"]
        let matched = Set(ReceiptScanner.matchingIDs(ids, descriptor: descriptor))
        #expect(matched.contains("com.foo.Bar"))        // exact bundle id
        #expect(matched.contains("com.foo.Bar.pkg"))     // child of bundle id
        #expect(matched.contains("com.foo"))             // parent domain of bundle id
        #expect(matched.contains("com.foo.Helper"))      // nested helper id
        #expect(!matched.contains("com.other.Thing"))    // unrelated
        #expect(!matched.contains("com.foobar"))         // prefix collision, not a real parent
    }

    @Test func emptyDescriptorMatchesNothing() {
        let bare = AppDescriptor(bundleID: nil, name: "Whatever")
        #expect(ReceiptScanner.matchingIDs(["com.a.b", "com.c.d"], descriptor: bare).isEmpty)
    }

    @Test func receiptIDStripsExtension() {
        let item = FileItem(url: URL(fileURLWithPath: "/var/db/receipts/com.foo.Bar.plist"),
                            category: "Receipts", domain: .system, isDirectory: false)
        #expect(ReceiptScanner.receiptID(for: item) == "com.foo.Bar")
    }
}
