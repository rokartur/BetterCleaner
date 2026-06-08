import Testing
import Foundation
@testable import BetterCleaner

@Suite struct OrphanClassifyTests {
    private let index = InstalledAppsIndex(apps: [
        InstalledApp(url: URL(fileURLWithPath: "/Applications/Installed.app"),
                     bundleID: "com.installed.App", name: "Installed", isSystem: false),
    ])

    @Test func reverseDNSUnownedIsMedium() {
        #expect(OrphanScanner.classify(name: "com.ghost.App", resolvedID: "com.ghost.App",
                                       isDirectory: true, category: "Caches", index: index) == .medium)
    }

    @Test func reverseDNSOwnedIsNotOrphan() {
        #expect(OrphanScanner.classify(name: "com.installed.App", resolvedID: "com.installed.App",
                                       isDirectory: true, category: "Caches", index: index) == nil)
        // suffixed helper of an installed app is owned too
        #expect(OrphanScanner.classify(name: "com.installed.App.helper", resolvedID: "com.installed.App.helper",
                                       isDirectory: false, category: "Preferences", index: index) == nil)
    }

    @Test func appGroupContainerOfInstalledAppIsNotOrphan() {
        // App Group / shared containers prefix the owning bundle id with `group.`
        // and/or a 10-char Team ID. They belong to the installed app, not orphans.
        for name in ["group.com.installed.App",
                     "4FG648TM2A.group.com.installed.App",
                     "243LU875E5.groups.com.installed.App",
                     "6N38VWS5BX.com.installed.App"] {
            #expect(OrphanScanner.classify(name: name, resolvedID: name,
                                           isDirectory: true, category: "Group Containers", index: index) == nil,
                    "\(name) should be owned by the installed app")
        }
        // A prefixed container whose trailing id is NOT installed is still an orphan.
        #expect(OrphanScanner.classify(name: "group.com.ghost.App", resolvedID: "group.com.ghost.App",
                                       isDirectory: true, category: "Group Containers", index: index) == .medium)
    }

    @Test func sharedVendorFolderIsNotOrphan() {
        #expect(OrphanScanner.classify(name: "Google", resolvedID: "Google",
                                       isDirectory: true, category: "Application Support", index: index) == nil)
    }

    @Test func unknownAppNamedFolderIsLow() {
        #expect(OrphanScanner.classify(name: "Sublime Text", resolvedID: "Sublime Text",
                                       isDirectory: true, category: "Application Support", index: index) == .low)
    }

    @Test func nameMatchingIsOnlyForApplicationSupport() {
        // The same plain-name folder elsewhere isn't name-graded.
        #expect(OrphanScanner.classify(name: "Sublime Text", resolvedID: "Sublime Text",
                                       isDirectory: true, category: "Caches", index: index) == nil)
    }

    @Test func installedAppDisplayNameIsNotOrphan() {
        #expect(OrphanScanner.classify(name: "Installed", resolvedID: "Installed",
                                       isDirectory: true, category: "Application Support", index: index) == nil)
    }

    @Test func reverseDNSDetection() {
        #expect(OrphanScanner.isReverseDNS("com.foo.Bar"))
        #expect(!OrphanScanner.isReverseDNS(".hiddenfile"))
        #expect(!OrphanScanner.isReverseDNS("PlainName"))
    }

    @Test func extractsTopLevelAppFromBOMPaths() {
        // BOM lists files inside the bundle; the orphan-receipt audit reduces them
        // to the top-level .app bundle whose existence it then checks.
        let files = [
            URL(fileURLWithPath: "/Applications/Foo.app/Contents/MacOS/Foo"),
            URL(fileURLWithPath: "/Applications/Foo.app/Contents/Info.plist"),
            URL(fileURLWithPath: "/usr/local/bin/foo-cli"),
            URL(fileURLWithPath: "/Applications/Bar.app"),
        ]
        #expect(OrphanScanner.topLevelAppPaths(files) == ["/Applications/Foo.app", "/Applications/Bar.app"])
        // A receipt that installs no .app yields no app paths → never judged orphan.
        #expect(OrphanScanner.topLevelAppPaths([URL(fileURLWithPath: "/usr/local/bin/tool")]).isEmpty)
    }
}
