import AppKit

/// Orchestrates a *complete* uninstall of one app: not just trashing files, but
/// quitting the running process, unloading its launchd jobs (so a daemon can't
/// respawn its data), resetting its privacy permissions, forgetting its package
/// receipts, and clearing its Keychain items. Every privileged action is folded
/// into a single elevation via `PrivilegedExecutor`.
///
/// Pure of UI; run off the main thread. Reports a per-step `Summary` so the caller
/// can show what happened. File moves go to the Trash (recoverable); the
/// irreversible steps (TCC reset, force-kill, Keychain) are opt-out in Settings.
enum AppRemover {
    struct Options {
        var quit = true
        var forceKill = true
        var unloadLaunchItems = true
        var resetTCC = true
        var forgetReceipts = true
        var keychain = true
    }

    enum Step: String, CaseIterable {
        case quit, forceKill, unloadLaunchItems, trash, forgetReceipts, resetTCC, keychain

        var title: String {
            switch self {
            case .quit: return "Quit app"
            case .forceKill: return "Stop helpers"
            case .unloadLaunchItems: return "Unload background items"
            case .trash: return "Move files to Trash"
            case .forgetReceipts: return "Forget package receipts"
            case .resetTCC: return "Reset privacy permissions"
            case .keychain: return "Remove Keychain items"
            }
        }
    }

    enum Outcome { case done, skipped, failed, cancelled }

    struct StepResult {
        let step: Step
        let outcome: Outcome
        let detail: String?
    }

    struct Plan {
        let app: InstalledApp
        let items: [FileItem]
        let options: Options
    }

    struct Summary {
        var results: [StepResult] = []
        var trashed: [URL] = []
        var failed: [URL] = []
        var cancelled = false
    }

    static func uninstall(_ plan: Plan, progress: ((Step) -> Void)? = nil) -> Summary {
        let app = plan.app
        let opts = plan.options
        let descriptor = app.descriptor
        var summary = Summary()
        var stepResults: [Step: StepResult] = [:]
        let part = partition(plan)

        // 1. Quit the running app + helpers (escalating to forceTerminate if the
        //    force option is on). Must precede trashing or flushed state returns.
        if opts.quit {
            progress?(.quit)
            let (outcome, detail) = quitRunningApps(app: app, force: opts.forceKill)
            stepResults[.quit] = StepResult(step: .quit, outcome: outcome, detail: detail)
        }

        // 2. Force-kill stragglers (XPC/login helpers) whose command line runs
        //    from inside the app bundle. Targeted at the bundle path, so nothing
        //    unrelated matches.
        if opts.forceKill {
            progress?(.forceKill)
            let (outcome, detail) = forceKillHelpers(app: app)
            stepResults[.forceKill] = StepResult(step: .forceKill, outcome: outcome, detail: detail)
        }

        // 3. Unload launchd jobs before their plists are removed. User agents
        //    bootout in the gui domain (no admin); system daemons go in the
        //    privileged batch below.
        if opts.unloadLaunchItems {
            progress?(.unloadLaunchItems)
            for args in part.userBootouts { _ = CommandRunner.run("/bin/launchctl", args) }
            stepResults[.unloadLaunchItems] = StepResult(
                step: .unloadLaunchItems,
                outcome: part.launchCount > 0 ? .done : .skipped,
                detail: part.launchCount > 0 ? "\(part.launchCount) unloaded" : nil
            )
        }

        // 4. Trash user-domain files via FileManager (no prompt). Anything that
        //    fails (e.g. a root-owned .app bundle) folds into the privileged batch
        //    below so the whole uninstall still costs a single elevation.
        progress?(.trash)
        let removedAt = Date()
        // Group the whole uninstall into one "<app> — <date>" folder in the Trash.
        let box = TrashBox.make(origin: plan.app.name, at: removedAt) ?? TrashBox.trashRoot
        var usedNames = Set<String>()
        let userResult = trashUserItems(part.userItems, origin: plan.app.name, at: removedAt, box: box, used: &usedNames)
        summary.trashed.append(contentsOf: userResult.trashed)

        // 5. Privileged batch: system bootouts + system-file moves into the box +
        //    any escalated user moves + CLI rm + receipt forgets, in ONE elevation.
        let sysPlan = privilegedPlan(for: plan, container: box, used: &usedNames)
        var privileged = sysPlan.commands
        privileged.append(contentsOf: PrivilegedRunner.moveCommands(
            container: box.path,
            pairs: userResult.escalated.map { (src: $0.url.path, dest: $0.dest.path) }))

        let batchSystemURLs = part.systemURLs + part.cliURLs + userResult.escalated.map(\.url)
        // Restore records for the batch (attached to history only if it runs).
        var batchSucceeded = false
        let systemRecords = privilegedRecords(
            systemMoves: sysPlan.moves,
            escalated: userResult.escalated,
            cliURLs: part.cliURLs,
            receiptIDs: part.receiptIDs,
            forgetReceipts: plan.options.forgetReceipts)

        if !privileged.isEmpty {
            do {
                try PrivilegedExecutor.runBatch(privileged)
                summary.trashed.append(contentsOf: batchSystemURLs)
                batchSucceeded = true
                if !part.receiptIDs.isEmpty {
                    stepResults[.forgetReceipts] = StepResult(step: .forgetReceipts, outcome: .done, detail: "\(part.receiptIDs.count) forgotten")
                }
            } catch PrivilegedExecutor.ExecError.cancelled {
                summary.cancelled = true
                summary.failed.append(contentsOf: batchSystemURLs)
                if !part.receiptIDs.isEmpty {
                    stepResults[.forgetReceipts] = StepResult(step: .forgetReceipts, outcome: .cancelled, detail: nil)
                }
            } catch {
                summary.failed.append(contentsOf: batchSystemURLs)
                if !part.receiptIDs.isEmpty {
                    stepResults[.forgetReceipts] = StepResult(step: .forgetReceipts, outcome: .failed, detail: "\(error)")
                }
            }
        }

        let trashedCount = summary.trashed.count
        stepResults[.trash] = StepResult(
            step: .trash,
            outcome: summary.failed.isEmpty ? (trashedCount > 0 ? .done : .skipped) : (summary.cancelled ? .cancelled : .failed),
            detail: "\(trashedCount) to Trash" + (summary.failed.isEmpty ? "" : " · \(summary.failed.count) failed")
        )

        // Record the uninstall in the trash history (which app, when, how much,
        // and per-file restore data). System-batch records are only attached when
        // the privileged batch actually ran.
        if !summary.trashed.isEmpty {
            let sizeByPath = Dictionary(part.userItems.map { ($0.url.path, $0.size) }, uniquingKeysWith: { a, _ in a })
            let bytes = summary.trashed.reduce(Int64(0)) { $0 + (sizeByPath[$1.path] ?? 0) }
            let files = userResult.records + (batchSucceeded ? systemRecords : [])
            TrashHistory.record(origin: plan.app.name, files: files, bytes: bytes, at: removedAt)
        }

        // 6. Reset the app's privacy grants (its own TCC entries — no admin).
        if opts.resetTCC {
            progress?(.resetTCC)
            let (outcome, detail) = resetPrivacy(descriptor: descriptor)
            stepResults[.resetTCC] = StepResult(step: .resetTCC, outcome: outcome, detail: detail)
        }

        // 7. Remove the app's Keychain items (bundle-id-scoped — see KeychainCleaner).
        if opts.keychain {
            progress?(.keychain)
            let removed = KeychainCleaner.deleteItems(matching: descriptor)
            stepResults[.keychain] = StepResult(step: .keychain, outcome: removed > 0 ? .done : .skipped, detail: removed > 0 ? "\(removed) removed" : nil)
        }

        summary.results = Step.allCases.compactMap { stepResults[$0] }
        return summary
    }

    // MARK: - Planning (pure, testable)

    private struct Partition {
        var userItems: [FileItem] = []
        var systemURLs: [URL] = []
        var cliURLs: [URL] = []
        var receiptIDs: [String] = []
        var userBootouts: [[String]] = []
        var systemBootouts: [String] = []
        var launchCount = 0
    }

    /// Split a plan's selected items into the user-domain trash set, the system
    /// URLs/CLI symlinks/receipt ids for the privileged batch, and the launchd
    /// bootout work.
    private static func partition(_ plan: Plan) -> Partition {
        let selected = plan.items.filter { $0.isSelected }
        let receiptItems = selected.filter { $0.category == "Receipts" }
        // CLI binaries and shell-completion scripts are usually symlinks into the
        // bundle; both go through the `rm -f` path (mv-to-trash refuses symlinks).
        let cliItems = selected.filter { $0.category == "Command Line Tools" || $0.category == "Shell Completions" }
        let fileItems = selected.filter { $0.category != "Receipts" && $0.category != "Command Line Tools" && $0.category != "Shell Completions" }

        var part = Partition()
        part.userItems = fileItems.filter { $0.domain == .user }
        part.systemURLs = fileItems.filter { $0.domain == .system }.map { $0.url }
        part.cliURLs = cliItems.map { $0.url }

        if plan.options.unloadLaunchItems {
            let bootouts = bootoutPlan(items: fileItems)
            // Helpers an app registers via SMAppService live INSIDE the bundle
            // (Contents/Library/Launch{Agents,Daemons}), so they never appear in the
            // ~/Library / /Library file scan and a bootout would miss them — leaving a
            // background item registered after the app is gone. Fold their labels in,
            // deduped against any installed copies already queued above.
            let embedded = embeddedBootouts(app: plan.app)
            var agentSeen = Set<String>()
            for args in bootouts.userAgents + embedded.userAgents {
                let key = args.last ?? args.joined(separator: " ")
                if agentSeen.insert(key).inserted { part.userBootouts.append(args) }
            }
            var daemonSeen = Set<String>()
            for cmd in bootouts.systemDaemons + embedded.systemDaemons where daemonSeen.insert(cmd).inserted {
                part.systemBootouts.append(cmd)
            }
            part.launchCount = part.userBootouts.count + part.systemBootouts.count
        }
        if plan.options.forgetReceipts {
            part.receiptIDs = receiptItems.map { ReceiptScanner.receiptID(for: $0) }
        } else {
            // Not forgetting → still remove the loose receipt files.
            part.systemURLs += receiptItems.map { $0.url }
        }
        return part
    }

    /// The privileged shell batch a plan would run — system daemon bootouts, then
    /// system-file moves into the Trash, then `rm -f` for CLI symlinks (which can't
    /// be trashed), then receipt forgets — without executing it. Pure; unit-tested
    /// to lock the command shape and option gating. Convenience overload used by
    /// tests; the live path uses `privilegedPlan(for:container:used:)`.
    static func privilegedCommands(for plan: Plan) -> [String] {
        var used = Set<String>()
        return privilegedPlan(for: plan, container: TrashBox.trashRoot, used: &used).commands
    }

    /// Build the privileged batch plus the system-file move mapping (so the caller
    /// can record per-file restore paths that match the commands). System files
    /// move into `container` under non-colliding names allocated via `used`.
    static func privilegedPlan(for plan: Plan, container: URL, used: inout Set<String>) -> (commands: [String], moves: [(url: URL, dest: URL)]) {
        let part = partition(plan)
        var commands = part.systemBootouts
        let moves = part.systemURLs.map { url -> (url: URL, dest: URL) in
            (url, container.appendingPathComponent(TrashBox.uniqueName(in: container, for: url.lastPathComponent, used: &used)))
        }
        commands.append(contentsOf: PrivilegedRunner.moveCommands(
            container: container.path,
            pairs: moves.map { (src: $0.url.path, dest: $0.dest.path) }))
        // CLI / shell-completion entries are symlinks (mv-to-trash refuses
        // symlinks); `rm -f` removes the link only, never the target, so it's safe.
        for url in part.cliURLs {
            commands.append("rm -f \(PrivilegedRunner.quote(url.path))")
        }
        for id in part.receiptIDs {
            commands.append("/usr/sbin/pkgutil --forget \(PrivilegedRunner.quote(id))")
        }
        return (commands, moves)
    }

    /// Restore records for everything the privileged batch touches: system-file and
    /// escalated-user moves are recoverable (under `container`); CLI symlinks
    /// (`rm -f`) and forgotten receipts are not.
    private static func privilegedRecords(systemMoves: [(url: URL, dest: URL)], escalated: [(url: URL, dest: URL)], cliURLs: [URL], receiptIDs: [String], forgetReceipts: Bool) -> [TrashHistory.FileRecord] {
        var records = (systemMoves + escalated).map {
            TrashHistory.FileRecord(originalPath: $0.url.path, trashPath: $0.dest.path, domain: "system", recoverable: true)
        }
        for url in cliURLs {
            records.append(TrashHistory.FileRecord(originalPath: url.path, trashPath: nil, domain: "system", recoverable: false))
        }
        if forgetReceipts {
            for id in receiptIDs {
                records.append(TrashHistory.FileRecord(originalPath: "pkg receipt: \(id)", trashPath: nil, domain: "system", recoverable: false))
            }
        }
        return records
    }

    /// Move user-domain items into the Trash `box` with `FileManager` (no prompt).
    /// Returns the moved URLs, the (src,dest) pairs that need privilege (folded into
    /// the single elevation rather than a second prompt), and restore records. Same
    /// protected/symlink guards as `Trasher`.
    private static func trashUserItems(_ items: [FileItem], origin: String, at date: Date, box: URL, used: inout Set<String>) -> (trashed: [URL], escalated: [(url: URL, dest: URL)], records: [TrashHistory.FileRecord]) {
        let fm = FileManager.default
        var trashed: [URL] = []
        var escalated: [(url: URL, dest: URL)] = []
        var records: [TrashHistory.FileRecord] = []
        for item in items {
            if FileMatcher.isProtected(url: item.url) { continue }
            if FileMatcher.isProtected(url: item.url.resolvingSymlinksInPath()) { continue }
            if (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            // Stamp provenance (app + time) before the move into the Trash.
            TrashMetadata.tag(item.url, origin: origin, at: date)
            let dest = box.appendingPathComponent(TrashBox.uniqueName(in: box, for: item.url.lastPathComponent, used: &used))
            do {
                try fm.moveItem(at: item.url, to: dest)
                trashed.append(item.url)
                records.append(TrashHistory.FileRecord(originalPath: item.url.path, trashPath: dest.path, domain: "user", recoverable: true))
            } catch {
                escalated.append((item.url, dest))
            }
        }
        return (trashed, escalated, records)
    }

    // MARK: - Steps

    /// Quit every running app/helper that is this bundle (by id or by living
    /// inside the bundle). Polls for graceful exit, escalating to forceTerminate
    /// when `force` is set. Never targets BetterCleaner itself.
    private static func quitRunningApps(app: InstalledApp, force: Bool) -> (Outcome, String?) {
        let appPath = app.url.standardizedFileURL.path
        let bids = app.descriptor.allBundleIDs
        let selfPid = getpid()

        func targets() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { ra in
                if ra.processIdentifier == selfPid { return false }
                if let p = ra.bundleURL?.standardizedFileURL.path, p == appPath || p.hasPrefix(appPath + "/") { return true }
                if let bid = ra.bundleIdentifier?.lowercased(),
                   bids.contains(where: { bid == $0 || bid.hasPrefix($0 + ".") }) { return true }
                return false
            }
        }

        let initial = targets()
        guard !initial.isEmpty else { return (.skipped, nil) }
        for ra in initial { ra.terminate() }

        var remaining = initial
        for _ in 0..<15 {
            remaining = targets()
            if remaining.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if remaining.isEmpty { return (.done, "\(initial.count) quit") }

        if force {
            for ra in remaining { ra.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
            remaining = targets()
        }
        return remaining.isEmpty ? (.done, "\(initial.count) quit") : (.failed, "\(remaining.count) still running")
    }

    /// `pkill -f <bundle path>` — kills any process whose command line runs from
    /// inside the bundle (helpers that ignore terminate). The full bundle path is
    /// specific enough that nothing unrelated matches.
    private static func forceKillHelpers(app: InstalledApp) -> (Outcome, String?) {
        let path = app.url.standardizedFileURL.path
        guard path.count >= 4, FileManager.default.isExecutableFile(atPath: "/usr/bin/pkill") else { return (.skipped, nil) }
        let out = CommandRunner.run("/usr/bin/pkill", ["-f", path])
        // Exit 0 = killed something; 1 = nothing matched (also fine).
        return out.status == 0 ? (.done, nil) : (.skipped, nil)
    }

    private struct BootoutPlan {
        var userAgents: [[String]] = []
        var systemDaemons: [String] = []
        var count = 0
    }

    /// Map selected launch items to `launchctl bootout` invocations: agents in the
    /// user gui domain (no admin), daemons in the system domain (privileged).
    private static func bootoutPlan(items: [FileItem]) -> BootoutPlan {
        let uid = String(getuid())
        var plan = BootoutPlan()
        for item in items where item.category == "LaunchAgents" || item.category == "LaunchDaemons" {
            guard let label = LaunchDaemonScanner.label(of: item.url) else { continue }
            plan.count += 1
            if item.category == "LaunchAgents" {
                plan.userAgents.append(["bootout", "gui/\(uid)/\(label)"])
            } else {
                plan.systemDaemons.append("/bin/launchctl bootout \(PrivilegedRunner.quote("system/\(label)"))")
            }
        }
        return plan
    }

    /// Bootout work for launchd helpers embedded inside the app bundle
    /// (`Contents/Library/LaunchAgents` / `LaunchDaemons`) — the location an app
    /// using `SMAppService` registers from, so these plists never reach the scanned
    /// Library directories. Reading each plist's `Label` lets us stop and unregister
    /// the job (user agents in the gui domain; system daemons in the privileged
    /// batch) before the bundle is trashed, after which the launchd/BTM record has no
    /// binary left to relaunch and macOS prunes the stale "background item" entry.
    private static func embeddedBootouts(app: InstalledApp) -> BootoutPlan {
        let fm = FileManager.default
        let uid = String(getuid())
        let libraryDir = app.url.appendingPathComponent("Contents/Library", isDirectory: true)
        var plan = BootoutPlan()
        for (sub, isAgent) in [("LaunchAgents", true), ("LaunchDaemons", false)] {
            let dir = libraryDir.appendingPathComponent(sub, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "plist" {
                guard let label = LaunchDaemonScanner.label(of: url) else { continue }
                plan.count += 1
                if isAgent {
                    plan.userAgents.append(["bootout", "gui/\(uid)/\(label)"])
                } else {
                    plan.systemDaemons.append("/bin/launchctl bootout \(PrivilegedRunner.quote("system/\(label)"))")
                }
            }
        }
        return plan
    }

    private static func resetPrivacy(descriptor: AppDescriptor) -> (Outcome, String?) {
        let tccutil = "/usr/bin/tccutil"
        guard FileManager.default.isExecutableFile(atPath: tccutil) else { return (.skipped, nil) }
        let ids = descriptor.allBundleIDs
        guard !ids.isEmpty else { return (.skipped, nil) }
        var ok = 0
        for id in ids where CommandRunner.run(tccutil, ["reset", "All", id]).ok { ok += 1 }
        return ok > 0 ? (.done, "\(ok) reset") : (.skipped, nil)
    }
}
