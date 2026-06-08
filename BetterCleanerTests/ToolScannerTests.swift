import Testing
import Foundation
@testable import BetterCleaner

/// Pure-parsing + sanitization tests for the CLI-backed tool scanners. The
/// `Process` calls themselves are not exercised (that would require brew/pkgutil
/// installed); only the deterministic text parsing and shell quoting are.

@Suite struct PackageScannerParseTests {
    @Test func parsesPackageList() {
        let ids = PackageScanner.parsePackageList("""
        com.apple.pkg.CLTools_Executables
        com.foo.Bar

        com.example.Thing
        """)
        #expect(ids == ["com.apple.pkg.CLTools_Executables", "com.foo.Bar", "com.example.Thing"])
    }

    @Test func parsesPkgInfoVersionAndLocation() {
        let info = """
        package-id: com.foo.Bar
        version: 3.2.1
        volume: /
        location: Applications/Foo.app
        install-time: 1700000000
        """
        let parsed = PackageScanner.parsePkgInfo(info)
        #expect(parsed.version == "3.2.1")
        #expect(parsed.location == "Applications/Foo.app")
    }

    @Test func pkgInfoMissingFieldsAreEmpty() {
        let parsed = PackageScanner.parsePkgInfo("package-id: com.foo.Bar\n")
        #expect(parsed.version == "")
        #expect(parsed.location == "")
    }
}

@Suite struct LaunchctlParseTests {
    @Test func parsesLabelsSkippingHeader() {
        let out = """
        PID\tStatus\tLabel
        123\t0\tcom.apple.foo
        -\t0\tcom.example.bar
        456\t-9\tcom.example.baz
        """
        let labels = LaunchDaemonScanner.parseLoadedLabels(out)
        #expect(labels.contains("com.apple.foo"))
        #expect(labels.contains("com.example.bar"))
        #expect(labels.contains("com.example.baz"))
        // The header's "Label" column value isn't a real label.
        #expect(!labels.contains("PID"))
    }

    @Test func emptyOrHeaderOnlyYieldsNoLabels() {
        #expect(LaunchDaemonScanner.parseLoadedLabels("").isEmpty)
        #expect(LaunchDaemonScanner.parseLoadedLabels("PID\tStatus\tLabel").isEmpty)
    }
}

@Suite struct ShellQuoteTests {
    @Test func wrapsInSingleQuotes() {
        #expect(PrivilegedRunner.quote("/Applications/Foo.app") == "'/Applications/Foo.app'")
    }

    @Test func preservesSpaces() {
        #expect(PrivilegedRunner.quote("/Users/x/Foo Bar.app") == "'/Users/x/Foo Bar.app'")
    }

    @Test func escapesEmbeddedSingleQuote() {
        // a'b → 'a'\''b'  (close quote, escaped literal quote, reopen quote)
        #expect(PrivilegedRunner.quote("a'b") == "'a'\\''b'")
    }

    @Test func neutralizesShellMetacharacters() {
        // A path crafted to break out of a command stays a single inert argument
        // (no embedded quote to escape → wrapped verbatim).
        #expect(PrivilegedRunner.quote("/tmp/x; rm -rf ~") == "'/tmp/x; rm -rf ~'")
    }

    @Test func quoteInjectionAttemptIsFullyEscaped() {
        // Each ' becomes '\'' so the payload can never close the literal early.
        // "'; rm -rf /; echo '"  →  ''\''; rm -rf /; echo '\'''
        let quoted = PrivilegedRunner.quote("'; rm -rf /; echo '")
        #expect(quoted == "''\\''; rm -rf /; echo '\\'''")
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
    }
}
