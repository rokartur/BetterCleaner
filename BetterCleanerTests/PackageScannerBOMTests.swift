import Testing
import Foundation
@testable import BetterCleaner

@Suite struct PackageScannerBOMTests {
    @Test func absolutePathsStripDotAndPrefixRoot() {
        let lsbom = "./Applications/Foo.app/Contents\n.\n./usr/local/bin/foo\n"
        let out = PackageScanner.absolutePaths(fromLsbom: lsbom, root: "/")
        #expect(out == ["/Applications/Foo.app/Contents", "/usr/local/bin/foo"])
    }

    @Test func absolutePathsRespectInstallRoot() {
        let lsbom = "./Contents/MacOS/Foo\n"
        let out = PackageScanner.absolutePaths(fromLsbom: lsbom, root: "/Applications/Foo.app")
        #expect(out == ["/Applications/Foo.app/Contents/MacOS/Foo"])
    }

    @Test func installRootCombinesVolumeAndLocation() {
        #expect(PackageScanner.installRoot(fromPkgInfo: "volume: /\nlocation: Applications/Foo.app\n") == "/Applications/Foo.app")
        // Empty volume defaults to "/", empty location keeps root.
        #expect(PackageScanner.installRoot(fromPkgInfo: "version: 1.0\n") == "/")
    }

    @Test func installDateParsesEpoch() {
        let date = PackageScanner.installDate(fromPkgInfo: "install-time: 1600000000\n")
        #expect(date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(PackageScanner.installDate(fromPkgInfo: "version: 1.0\n") == nil)
        #expect(PackageScanner.installDate(fromPkgInfo: "install-time: 0\n") == nil)
    }

    @Test func systemPackagesAreOSInstallerNamespacesOnly() {
        // macOS installer components + system templates are hidden…
        #expect(PackageScanner.isSystemPackage(id: "com.apple.pkg.CLTools_Executables"))
        #expect(PackageScanner.isSystemPackage(id: "COM.APPLE.PKG.XProtectPayloads_10_15"))
        #expect(PackageScanner.isSystemPackage(id: "com.apple.files.data-template"))
        // …but Apple tools the user installed separately still show.
        #expect(!PackageScanner.isSystemPackage(id: "com.apple.container-installer"))
        #expect(!PackageScanner.isSystemPackage(id: "com.apple.dt.Xcode"))
        // Third-party ids — including a vendor whose name starts with "apple" — stay.
        #expect(!PackageScanner.isSystemPackage(id: "com.applesauce.tool"))
        #expect(!PackageScanner.isSystemPackage(id: "com.google.Chrome"))
        #expect(!PackageScanner.isSystemPackage(id: "org.videolan.vlc"))
    }

    @Test func parseFieldReadsNamedLine() {
        let info = "package-id: com.foo.bar\nversion: 2.5\nlocation: Applications\n"
        #expect(PackageScanner.parseField(info, "version") == "2.5")
        #expect(PackageScanner.parseField(info, "location") == "Applications")
        #expect(PackageScanner.parseField(info, "missing") == "")
    }

    @Test func exclusivePackageFilesAndReceiptAreRemovable() {
        let appPath = "/Applications/Foo.app"
        let records = [PackageOwnership.PackageRecord(
            id: "com.example.foo",
            files: [URL(fileURLWithPath: appPath), URL(fileURLWithPath: "/Library/Foo/helper")],
            appPaths: [appPath]
        )]

        let result = PackageOwnership.resolve(
            appPath: appPath,
            records: records,
            installedAppPaths: [appPath]
        )

        #expect(result.files == [PackageOwnership.OwnedFile(
            url: URL(fileURLWithPath: "/Library/Foo/helper"),
            isExclusiveToApp: true
        )])
        #expect(result.removableReceiptIDs == ["com.example.foo"])
        #expect(result.sharedReceiptIDs.isEmpty)
    }

    @Test func suitePackageNeverOffersSiblingAppOrReceipt() {
        let foo = "/Applications/Foo.app"
        let bar = "/Applications/Bar.app"
        let records = [PackageOwnership.PackageRecord(
            id: "com.example.suite",
            files: [
                URL(fileURLWithPath: foo),
                URL(fileURLWithPath: bar),
                URL(fileURLWithPath: "/Library/Application Support/Example/shared.db"),
            ],
            appPaths: [foo, bar]
        )]

        let result = PackageOwnership.resolve(
            appPath: foo,
            records: records,
            installedAppPaths: [foo, bar]
        )

        #expect(result.files == [PackageOwnership.OwnedFile(
            url: URL(fileURLWithPath: "/Library/Application Support/Example/shared.db"),
            isExclusiveToApp: false
        )])
        #expect(result.removableReceiptIDs.isEmpty)
        // Listed so the user can still forget it by hand, never pre-selected.
        #expect(result.sharedReceiptIDs == ["com.example.suite"])
    }

    /// A bundled updater is not a second product: it is not itself an installed
    /// app, so the package stays exclusive and the updater remains removable
    /// rather than being hidden as a sibling.
    @Test func bundledHelperAppIsNotASibling() {
        let foo = "/Applications/Foo.app"
        let updater = "/Library/Application Support/Foo/Foo Updater.app"
        let records = [PackageOwnership.PackageRecord(
            id: "com.example.foo",
            files: [URL(fileURLWithPath: foo), URL(fileURLWithPath: updater)],
            appPaths: [foo, updater]
        )]

        let result = PackageOwnership.resolve(
            appPath: foo,
            records: records,
            installedAppPaths: [foo, "/Applications/Unrelated.app"]
        )

        #expect(result.files == [PackageOwnership.OwnedFile(
            url: URL(fileURLWithPath: updater),
            isExclusiveToApp: true
        )])
        #expect(result.removableReceiptIDs == ["com.example.foo"])
    }

    /// The Finder extension deep-links into a scan before the app inventory is
    /// built. An empty inventory means "unknown", never "nothing else installed".
    @Test func emptyInventoryTreatsPackageAsShared() {
        let foo = "/Applications/Foo.app"
        let bar = "/Applications/Bar.app"
        let records = [PackageOwnership.PackageRecord(
            id: "com.example.suite",
            files: [URL(fileURLWithPath: foo), URL(fileURLWithPath: bar), URL(fileURLWithPath: "/Library/x/s.db")],
            appPaths: [foo, bar]
        )]

        let result = PackageOwnership.resolve(appPath: foo, records: records, installedAppPaths: [])

        #expect(result.files == [PackageOwnership.OwnedFile(
            url: URL(fileURLWithPath: "/Library/x/s.db"),
            isExclusiveToApp: false
        )])
        #expect(result.removableReceiptIDs.isEmpty)
        #expect(result.sharedReceiptIDs == ["com.example.suite"])
    }

    /// `ReceiptScanner.matchingIDs` matches parent namespaces too, so a receipt
    /// that never mentions this app can still be listed. If it owns another
    /// installed app it must not arrive pre-selected for `pkgutil --forget`.
    @Test func receiptOwningOnlyAnotherInstalledAppIsShared() {
        let foo = "/Applications/Foo.app"
        let bar = "/Applications/Bar.app"
        let records = [
            PackageOwnership.PackageRecord(
                id: "com.example.foo",
                files: [URL(fileURLWithPath: foo)],
                appPaths: [foo]
            ),
            PackageOwnership.PackageRecord(
                id: "com.example",
                files: [URL(fileURLWithPath: bar)],
                appPaths: [bar]
            )
        ]

        let result = PackageOwnership.resolve(
            appPath: foo,
            records: records,
            installedAppPaths: [foo, bar]
        )

        #expect(result.removableReceiptIDs == ["com.example.foo"])
        #expect(result.sharedReceiptIDs == ["com.example"])
    }
}
