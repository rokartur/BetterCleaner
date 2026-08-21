import Foundation

/// A category group of scan results, ready for the outline view.
struct ScanSection {
    let category: String
    var items: [FileItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Finds the files associated with a single installed app.
enum LeftoverScanner {
    /// Scan synchronously. Callers should run this off the main thread; independent
    /// location walks and recursive size measurements use at most four workers.
    static func scan(
        app: InstalledApp,
        sensitivity: SearchSensitivity,
        includeSystem: Bool,
        otherApps: [InstalledApp] = [],
        excluded: Set<String> = [],
        conditions: [UserCondition] = [],
        isCancelled: @escaping () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) -> [FileItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let descriptor = app.descriptor
        var results: [FileItem] = []
        var seen = Set<String>()
        func add(_ items: [FileItem]) {
            for item in items where seen.insert(item.url.standardizedFileURL.path).inserted {
                results.append(item)
            }
        }
        progress?(0)

        let appPath = app.url.standardizedFileURL.path
        // A second copy of the same app — a backup volume, a duplicate in
        // ~/Applications — is not a competitor. Left in, it would collide with its
        // own bundle id and vendor token and veto every match this scan makes.
        let competitors = otherApps.filter { other in
            if other.url.standardizedFileURL.path == appPath { return false }
            if let id = app.bundleID, other.bundleID == id { return false }
            return true
        }
        let context = CollectionContext(
            descriptor: descriptor,
            sensitivity: sensitivity,
            promoteVendor: vendorIsExclusive(app: app, competitors: competitors),
            appTeam: app.teamID ?? CodeSigning.teamID(of: app.url),
            collisions: FileMatcher.CollisionIndex(competitors.map(\.descriptor)),
            excluded: excluded,
            conditions: ConditionEvaluator(conditions: conditions, descriptor: descriptor),
            isCancelled: isCancelled
        )

        if !app.isSystem {
            seen.insert(appPath)
            results.append(FileItem(
                url: app.url,
                category: "Application",
                domain: .user,
                isDirectory: true,
                isSelected: true
            ))
        }

        let locations = Locations.locations(includeSystem: includeSystem)
            + Locations.perUserTempLocations()
            + Locations.homeLeftoverLocations()
        var perLocation = [[FileItem]](repeating: [], count: locations.count)
        let workerCount = min(4, locations.count)
        let walked = ProgressCounter(total: locations.count, upTo: 0.6, report: progress)
        perLocation.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                for index in stride(from: worker, to: locations.count, by: workerCount) {
                    guard !isCancelled() else { return }
                    buffer[index] = collect(locations[index], context: context)
                    walked.step()
                }
            }
        }
        for items in perLocation { add(items) }
        progress?(0.6)
        if isCancelled() { return results }

        let packageOwnership = PackageOwnership.ownership(
            for: app,
            otherApps: competitors,
            isCancelled: isCancelled
        )
        add(packageOwnership.files.compactMap { ownedFile -> FileItem? in
            let url = ownedFile.url
            guard !FileMatcher.isProtected(url: url), !ScanExclusions.isExcluded(url, in: excluded) else {
                return nil
            }
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDirectory)
            return FileItem(
                url: url,
                category: "Package Files",
                domain: path.hasPrefix(home + "/") ? .user : .system,
                isDirectory: isDirectory.boolValue,
                isSelected: ownedFile.isExclusiveToApp,
                isAutoSelectable: ownedFile.isExclusiveToApp
            )
        })
        progress?(0.72)
        if isCancelled() { return results }

        add(ReceiptScanner.fileItems(
            for: descriptor,
            additionalIDs: packageOwnership.removableReceiptIDs,
            sharedIDs: packageOwnership.sharedReceiptIDs
        ))
        progress?(0.78)

        add(cliToolItems(for: app))
        progress?(0.84)

        add(SpotlightScanner.scan(
            app: app,
            seenPaths: seen,
            otherAppPaths: Set(competitors.map { $0.url.standardizedFileURL.path }),
            includeSystem: includeSystem,
            excluded: excluded,
            isCancelled: isCancelled
        ))
        progress?(0.92)

        measure(items: results, isCancelled: isCancelled, progress: progress)
        progress?(1)
        return results
    }

    /// Whether this app's vendor token(s) are used by no other installed app, so
    /// vendor-named leftovers ("Parallels", `com.parallels.*`) unambiguously
    /// belong to it and can be auto-selected. False (conservative) when the vendor
    /// is shared (e.g. several `com.google.*` apps) or unknown.
    private static func vendorIsExclusive(app: InstalledApp, competitors: [InstalledApp]) -> Bool {
        let appVendors = Set(FileMatcher.vendorTokens(app.descriptor))
        guard !appVendors.isEmpty else { return false }
        var otherVendors = Set<String>()
        for other in competitors {
            otherVendors.formUnion(FileMatcher.vendorTokens(other.descriptor))
        }
        return appVendors.isDisjoint(with: otherVendors)
    }

    /// Symlinks under `/usr/local/{bin,sbin}` whose target resolves inside the
    /// app bundle — CLI tools an installer added to PATH. A target inside the
    /// bundle is an unambiguous (strong) signal, so these are pre-selected.
    private static func cliToolItems(for app: InstalledApp) -> [FileItem] {
        let fm = FileManager.default
        let appPath = app.url.standardizedFileURL.path
        var items: [FileItem] = []
        for dir in ["/usr/local/bin", "/usr/local/sbin"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                let linkPath = dir + "/" + name
                // destinationOfSymbolicLink throws for non-symlinks → filters them.
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else { continue }
                let resolved = dest.hasPrefix("/")
                    ? URL(fileURLWithPath: dest).standardizedFileURL.path
                    : URL(fileURLWithPath: dir).appendingPathComponent(dest).standardizedFileURL.path
                guard resolved == appPath || resolved.hasPrefix(appPath + "/") else { continue }
                items.append(FileItem(url: URL(fileURLWithPath: linkPath), category: "Command Line Tools",
                                      domain: .system, isDirectory: false, isSelected: true))
            }
        }
        return items
    }

    private struct CollectionContext {
        let descriptor: AppDescriptor
        let sensitivity: SearchSensitivity
        let promoteVendor: Bool
        let appTeam: String?
        let collisions: FileMatcher.CollisionIndex
        let excluded: Set<String>
        let conditions: ConditionEvaluator
        let isCancelled: () -> Bool
    }

    private static func collect(_ target: LibraryLocation, context: CollectionContext) -> [FileItem] {
        var items: [FileItem] = []
        collect(in: target.url, target: target, context: context, remainingDepth: target.depth, items: &items)
        return items
    }

    /// A matched folder is taken whole. Unmatched folders are followed only to
    /// the target's bounded depth; weak signals are accepted in the first two levels.
    private static func collect(
        in directory: URL,
        target: LibraryLocation,
        context: CollectionContext,
        remainingDepth: Int,
        items: inout [FileItem]
    ) {
        guard !context.isCancelled() else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: target.hiddenLeftoversOnly ? [] : [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            if target.hiddenLeftoversOnly, !url.lastPathComponent.hasPrefix(".") { continue }
            if FileMatcher.isProtected(url: url) || ScanExclusions.isExcluded(url, in: context.excluded) { continue }

            // Prefetched resource value, so the walk does not stat every entry a
            // second time. Unlike `fileExists(isDirectory:)` it does not follow
            // symlinks: a symlinked folder counts as a file and is not descended
            // into, which is what the sizing guard assumes too.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let decision = context.conditions.isEmpty
                ? ConditionEvaluator.Decision.none
                : context.conditions.decide(fileName: url.lastPathComponent, path: url.path)
            if decision == .forceExclude { continue }

            let resolvesContainerID = target.resolvesContainerID && remainingDepth == target.depth
            let match = candidateMatch(
                url: url,
                isDirectory: isDirectory,
                resolvesContainerID: resolvesContainerID,
                context: context
            )

            if match == nil, decision == .forceInclude, target.domain != .system,
               !FileMatcher.isProtected(url: url.resolvingSymlinksInPath()) {
                items.append(FileItem(
                    url: url,
                    category: target.category,
                    domain: target.domain,
                    isDirectory: isDirectory,
                    isAutoSelectable: false
                ))
                continue
            }

            let isShallowLevel = target.depth - remainingDepth <= 1
            if let match, match.strength == .strong || isShallowLevel || context.promoteVendor {
                let selected = shouldSelect(match: match, url: url, target: target, context: context)
                items.append(FileItem(
                    url: url,
                    category: target.category,
                    domain: target.domain,
                    isDirectory: isDirectory,
                    isSelected: selected,
                    isAutoSelectable: selected
                ))
                continue
            }

            if remainingDepth > 1, isDirectory {
                collect(
                    in: url,
                    target: target,
                    context: context,
                    remainingDepth: remainingDepth - 1,
                    items: &items
                )
            }
        }
    }

    private static func candidateMatch(
        url: URL,
        isDirectory: Bool,
        resolvesContainerID: Bool,
        context: CollectionContext
    ) -> FileMatcher.Match? {
        var match = FileMatcher.classify(
            fileName: url.lastPathComponent,
            descriptor: context.descriptor,
            sensitivity: context.sensitivity
        )
        if match == nil, resolvesContainerID, isDirectory,
           let identifier = FileMatcher.containerIdentifier(of: url),
           FileMatcher.containerMatches(identifier: identifier, descriptor: context.descriptor) {
            match = FileMatcher.Match(strength: .strong, kind: .bundleID)
        }
        if match == nil, context.sensitivity != .strict, isDirectory,
           FileMatcher.looksOpaque(url.lastPathComponent),
           let identifier = FileMatcher.metadataBundleID(of: url),
           FileMatcher.containerMatches(identifier: identifier, descriptor: context.descriptor) {
            match = FileMatcher.Match(strength: .strong, kind: .bundleID)
        }
        if match == nil, context.sensitivity != .strict, let appTeam = context.appTeam, isDirectory,
           SpotlightScanner.isCodeBundle(url.lastPathComponent),
           CodeSigning.teamID(of: url) == appTeam {
            match = FileMatcher.Match(strength: .weak, kind: .vendor)
        }
        return match
    }

    private static func shouldSelect(
        match: FileMatcher.Match,
        url: URL,
        target: LibraryLocation,
        context: CollectionContext
    ) -> Bool {
        guard target.autoSelectable else { return false }
        switch match.kind {
        case .bundleID:
            return match.strength == .strong
        case .name:
            return match.strength == .strong
                && !context.collisions.claims(
                    fileName: url.lastPathComponent,
                    sensitivity: context.sensitivity
                )
        case .vendor:
            return context.promoteVendor
        }
    }

    /// Sizes the discovered rows in parallel. `FileItem` is a class and each
    /// worker owns a disjoint stride of indices, so rows are written in place.
    /// Rows a cancel never reached show 0 B, and "Receipts" rows keep the size
    /// `ReceiptScanner` already summed across their two receipt files.
    private static func measure(
        items: [FileItem],
        isCancelled: @escaping () -> Bool,
        progress: ((Double) -> Void)? = nil
    ) {
        let workerCount = min(4, items.count)
        guard workerCount > 0 else { return }
        let sized = ProgressCounter(total: items.count, from: 0.92, upTo: 1, report: progress)
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            for index in stride(from: worker, to: items.count, by: workerCount) {
                guard !isCancelled() else { return }
                let item = items[index]
                defer { sized.step() }
                guard item.category != "Receipts" else { continue }
                let measured = FileSize.sizeWithStatus(of: item.url, isCancelled: isCancelled)
                item.size = measured.bytes
                item.sizeIsApproximate = !measured.complete
            }
        }
    }

    /// Both heavy phases run on `concurrentPerform`, so their progress has to be
    /// counted across workers. Without it the determinate bar sits still through
    /// the walk and again through sizing, which is most of a scan.
    private final class ProgressCounter {
        private let lock = NSLock()
        private let total: Int
        private let from: Double
        private let span: Double
        private let report: ((Double) -> Void)?
        private var done = 0

        init(total: Int, from: Double = 0, upTo: Double, report: ((Double) -> Void)?) {
            self.total = total
            self.from = from
            self.span = upTo - from
            self.report = report
        }

        /// Reported under the lock so a slower worker cannot deliver a stale,
        /// smaller fraction after a faster one and tick the bar backwards.
        func step() {
            guard let report, total > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            done += 1
            report(from + span * Double(done) / Double(total))
        }
    }

    /// Group a flat result list into ordered, size-sorted sections.
    static func sections(from items: [FileItem]) -> [ScanSection] {
        var grouped: [String: [FileItem]] = [:]
        for item in items { grouped[item.category, default: []].append(item) }

        var sections: [ScanSection] = []
        for category in Locations.categoryOrder {
            if let items = grouped.removeValue(forKey: category), !items.isEmpty {
                sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
            }
        }
        // Any categories not in the canonical order (defensive) go last.
        for (category, items) in grouped.sorted(by: { $0.key < $1.key }) {
            sections.append(ScanSection(category: category, items: items.sorted { $0.size > $1.size }))
        }
        return sections
    }
}
