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
}
