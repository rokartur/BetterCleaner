import Testing
import Foundation
@testable import BetterCleaner

/// Tests the pure privileged-batch builder — the command shape and option gating
/// — without executing anything (no quit, no admin prompt, no real deletion).
@Suite struct AppRemoverPlanTests {
    private let app = InstalledApp(
        url: URL(fileURLWithPath: "/Applications/Foo.app"),
        bundleID: "com.foo.Bar", name: "Foo", isSystem: false
    )

    private func daemonPlist(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc-daemon-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "Program": "/bin/true"], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @Test func buildsBootoutMoveAndForgetInOrder() throws {
        let plist = try daemonPlist(label: "com.foo.daemon")
        defer { try? FileManager.default.removeItem(at: plist) }
        let items = [
            FileItem(url: plist, category: "LaunchDaemons", domain: .system, isDirectory: false, isSelected: true),
            FileItem(url: URL(fileURLWithPath: "/Library/Application Support/Foo/data"), category: "Application Support", domain: .system, isDirectory: true, isSelected: true),
            FileItem(url: URL(fileURLWithPath: "/var/db/receipts/com.foo.Bar.plist"), category: "Receipts", domain: .system, isDirectory: false, isSelected: true),
            // user-domain item must NOT enter the admin batch (it trashes without a prompt)
            FileItem(url: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/com.foo.Bar"), category: "Caches", domain: .user, isDirectory: true, isSelected: true),
        ]
        let plan = AppRemover.Plan(app: app, items: items, options: AppRemover.Options())
        let commands = AppRemover.privilegedCommands(for: plan)
        let joined = commands.joined(separator: "\n")

        #expect(joined.contains("launchctl bootout 'system/com.foo.daemon'"))
        #expect(joined.contains("/bin/mv -f '/Library/Application Support/Foo/data'"))
        #expect(joined.contains("pkgutil --forget 'com.foo.Bar'"))
        #expect(!joined.contains("Caches/com.foo.Bar")) // user file stays out of admin batch

        // Daemon must be unloaded before its plist/files are moved.
        let bootoutIdx = commands.firstIndex { $0.contains("bootout") }
        let mvIdx = commands.firstIndex { $0.contains("/bin/mv") }
        #expect(bootoutIdx != nil && mvIdx != nil && bootoutIdx! < mvIdx!)
    }

    @Test func receiptToggleSwitchesForgetVsMove() throws {
        let receipt = FileItem(url: URL(fileURLWithPath: "/var/db/receipts/com.foo.Bar.plist"),
                               category: "Receipts", domain: .system, isDirectory: false, isSelected: true)
        var opts = AppRemover.Options()
        opts.forgetReceipts = false
        let plan = AppRemover.Plan(app: app, items: [receipt], options: opts)
        let joined = AppRemover.privilegedCommands(for: plan).joined(separator: "\n")

        #expect(!joined.contains("pkgutil --forget"))                 // not forgotten
        #expect(joined.contains("/var/db/receipts/com.foo.Bar.plist")) // moved instead
    }

    @Test func unloadToggleOmitsBootout() throws {
        let plist = try daemonPlist(label: "com.foo.daemon")
        defer { try? FileManager.default.removeItem(at: plist) }
        var opts = AppRemover.Options()
        opts.unloadLaunchItems = false
        let plan = AppRemover.Plan(
            app: app,
            items: [FileItem(url: plist, category: "LaunchDaemons", domain: .system, isDirectory: false, isSelected: true)],
            options: opts
        )
        #expect(!AppRemover.privilegedCommands(for: plan).joined().contains("bootout"))
    }

    @Test func embeddedSMAppServiceDaemonIsBootedOut() throws {
        // An app that registered a daemon via SMAppService keeps its plist INSIDE the
        // bundle (Contents/Library/LaunchDaemons); the Library file scan never sees
        // it, so AppRemover must enumerate the bundle directly — even with no selected
        // file items — and bootout its label.
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc-\(UUID().uuidString).app", isDirectory: true)
        let daemons = bundle.appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.foo.embedded", "Program": "/bin/true"], format: .xml, options: 0)
        try data.write(to: daemons.appendingPathComponent("helper.plist"))

        let embeddedApp = InstalledApp(url: bundle, bundleID: "com.foo.Bar", name: "Foo", isSystem: false)
        let plan = AppRemover.Plan(app: embeddedApp, items: [], options: AppRemover.Options())
        let joined = AppRemover.privilegedCommands(for: plan).joined(separator: "\n")
        #expect(joined.contains("launchctl bootout 'system/com.foo.embedded'"))

        // Gated behind the unload option like every other bootout.
        var off = AppRemover.Options(); off.unloadLaunchItems = false
        let gatedPlan = AppRemover.Plan(app: embeddedApp, items: [], options: off)
        #expect(!AppRemover.privilegedCommands(for: gatedPlan).joined().contains("bootout"))
    }

    /// A partial uninstall used to look exactly like a complete one: the summary
    /// stayed silent whenever nothing outright failed, so items left behind on
    /// purpose vanished without a word.
    @Test func anUninstallThatLeftItemsBehindSaysSo() {
        let url = URL(fileURLWithPath: "/Library/Foo/x")
        var partial = AppRemover.Summary()
        partial.trashed = [url]
        partial.skipped = [url]
        #expect(partial.removal.incompleteMessage(verb: "removed")
            == "1 item was left in place (protected or a link).")

        var readOnly = AppRemover.Summary()
        readOnly.failed = [url]
        readOnly.failureReason = "The volume is read only."
        #expect(readOnly.removal.incompleteMessage(verb: "removed")
            == "0 removed, 1 failed (The volume is read only).")

        var clean = AppRemover.Summary()
        clean.trashed = [url]
        #expect(clean.removal.incompleteMessage(verb: "removed") == nil)
    }

    @Test func unselectedItemsProduceNoCommands() {
        let item = FileItem(url: URL(fileURLWithPath: "/Library/Foo/x"), category: "Application Support",
                            domain: .system, isDirectory: true, isSelected: false)
        let plan = AppRemover.Plan(app: app, items: [item], options: AppRemover.Options())
        #expect(AppRemover.privilegedCommands(for: plan).isEmpty)
    }
}
