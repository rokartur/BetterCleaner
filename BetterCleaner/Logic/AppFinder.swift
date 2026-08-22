import AppKit

/// Enumerates installed `.app` bundles and reads their identity.
enum AppFinder {

    static func defaultRoots() -> [URL] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Network/Applications", isDirectory: true),
        ]
        return roots.filter { fm.fileExists(atPath: $0.path) }
    }

    /// How deep to descend into subfolders of an app root. Apps frequently live one
    /// or two folders down — `/Applications/Utilities`, `/Applications/Setapp`,
    /// `/Applications/Adobe …/`, `~/Applications/JetBrains Toolbox` — so a top-level
    /// scan misses them. Bounded so a pathological deep tree can't stall the scan.
    private static let maxRootDepth = 4

    static func installedApps(extraRoots: [URL] = []) -> [InstalledApp] {
        let fm = FileManager.default
        let roots = defaultRoots() + extraRoots
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            let key = standardized.resolvingSymlinksInPath().path.lowercased()
            guard seen.insert(key).inserted,
                  let app = app(at: standardized, resolveTeamID: false) else { return }
            apps.append(app)
        }

        for root in roots {
            for url in appBundles(under: root, fm: fm) { append(url) }
        }
        for url in spotlightAppBundles(allowedRoots: roots) { append(url) }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Spotlight adds hidden apps under known roots and apps on writable external
    /// volumes without recursively walking every mounted disk. Unindexed volumes
    /// remain available through the user-configured extra roots.
    private static func spotlightAppBundles(allowedRoots: [URL]) -> [URL] {
        let query = "kMDItemContentType == \"com.apple.application-bundle\"cd"
        let rootPaths = allowedRoots.map { $0.standardizedFileURL.path }
        return SpotlightScanner.mdfindPaths(query)
            .filter { url in
                guard url.pathExtension.lowercased() == "app",
                      !ScanExclusions.isInTrash(url.path),
                      !isNestedApplication(url) else { return false }
                if rootPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                    return true
                }
                return url.path.hasPrefix("/Volumes/") && isWritableVolume(url)
            }
    }

    private static func isNestedApplication(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.dropLast().contains {
            $0.lowercased().hasSuffix(".app")
        }
    }

    /// Fails open: an unreadable volume flag should not hide an installed app.
    private static func isWritableVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
    }

    /// Every `.app` bundle at or below `root`, recursing through plain subfolders
    /// but never *into* an app bundle (`.skipsPackageDescendants`), bounded to
    /// `maxRootDepth` levels. Catches apps nested in vendor/launcher subfolders that
    /// a single-level `contentsOfDirectory` scan would miss.
    private static func appBundles(under root: URL, fm: FileManager) -> [URL] {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                found.append(url)
                continue
            }
            // Stop descending once we're `maxRootDepth` folders below the root.
            if url.standardizedFileURL.pathComponents.count - rootDepth >= maxRootDepth {
                enumerator.skipDescendants()
            }
        }
        return found
    }

    /// Build an `InstalledApp` from a bundle URL, reading its identifier, name,
    /// executable, and the bundle ids of any nested helpers. `resolveTeamID:false`
    /// skips the (relatively costly) code-signing Team ID read for bulk listing;
    /// callers that need ownership evidence (the leftover scan) pass `true`.
    static func app(at url: URL, resolveTeamID: Bool = true) -> InstalledApp? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        // Must be a real bundle directory that exists — guards against a deep-link
        // / Finder-extension path like "/tmp/fake.app" that isn't an app bundle.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        // A bundle in the Trash isn't "installed" — guard against a user-added
        // Trash scan root or a drag-drop / deep-link of an already-trashed app.
        if ScanExclusions.isInTrash(url.standardizedFileURL.path) { return nil }
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = displayName ?? bundleName ?? url.deletingPathExtension().lastPathComponent
        let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        let shortVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let isSystem = isSystemBundle(url)
        let nested = nestedBundleIDs(in: url, excluding: bundleID)
        return InstalledApp(
            url: url,
            bundleID: bundleID,
            name: name,
            bundleName: bundleName,
            executable: executable,
            extraBundleIDs: nested,
            isSystem: isSystem,
            teamID: resolveTeamID ? CodeSigning.teamID(of: url) : nil,
            shortVersion: shortVersion
        )
    }

    /// A bundle Apple owns and SIP protects: everything under `/System/`, plus
    /// the built-ins Apple links into `/Applications` from a cryptex (Safari).
    /// The restricted flag lives on the symlink itself, so `lstat` — not `stat`.
    /// An unreadable bundle counts as system: `isSystem` gates removal, so the
    /// uncertain case must point away from deleting Apple's files.
    static func isSystemBundle(_ url: URL) -> Bool {
        if url.path.hasPrefix("/System/") { return true }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    /// Harvest bundle ids from the helpers an app embeds — login items, plug-ins,
    /// XPC services, system extensions. Files these helpers leave behind carry
    /// *their* ids, so attributing them to the parent app removes the leftovers
    /// a name/bundle-id-only scan would miss.
    private static func nestedBundleIDs(in appURL: URL, excluding primary: String?) -> [String] {
        let fm = FileManager.default
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helperDirs = [
            "Library/LoginItems",
            "Library/SystemExtensions",
            "Library/Spotlight",
            "Library/QuickLook",
            "PlugIns",
            "Extensions",
            "XPCServices",
            "Frameworks",
        ]
        var ids = Set<String>()
        for sub in helperDirs {
            let dir = contents.appendingPathComponent(sub, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                if sub == "Frameworks", !["app", "xpc"].contains(entry.pathExtension.lowercased()) {
                    continue
                }
                guard let id = Bundle(url: entry)?.bundleIdentifier, id != primary else { continue }
                ids.insert(id)
            }
        }
        return Array(ids).sorted()
    }
}

/// Fast membership index over installed apps, used by the orphan scanner to tell
/// whether a leftover file still has an owner.
final class InstalledAppsIndex {
    private let bundleIDs: Set<String>
    private let normalizedNames: Set<String>

    init(apps: [InstalledApp]) {
        var ids = Set<String>()
        var names = Set<String>()
        for app in apps {
            if let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty {
                ids.insert(bundleID)
            }
            for extraBundleID in app.extraBundleIDs {
                let bundleID = extraBundleID.lowercased()
                if !bundleID.isEmpty { ids.insert(bundleID) }
            }
            let normalizedName = FileMatcher.normalize(app.name)
            if !normalizedName.isEmpty { names.insert(normalizedName) }
            if let executable = app.executable {
                let normalizedExecutable = FileMatcher.normalize(executable)
                if !normalizedExecutable.isEmpty { names.insert(normalizedExecutable) }
            }
        }
        bundleIDs = ids
        normalizedNames = names
    }

    /// True if an installed app owns this identifier. Matches three real-world
    /// shapes the orphan scanner meets:
    ///  - exact bundle id (`com.foo.Bar`),
    ///  - a dotted child — helpers/extensions (`com.foo.Bar.helper` ← `com.foo.Bar`),
    ///  - a prefixed App-Group / shared container, where the owning id is a dotted
    ///    *suffix*: `group.com.foo.Bar`, `4FG648TM2A.group.com.foo.Bar`,
    ///    `243LU875E5.groups.com.foo.Bar`, `TEAMID.com.foo.Bar` ← `com.foo.Bar`.
    func ownsIdentifier(_ candidate: String) -> Bool {
        let normalizedCandidate = candidate.lowercased()
        if bundleIDs.contains(normalizedCandidate) { return true }
        for id in bundleIDs where !id.isEmpty {
            if normalizedCandidate.hasPrefix(id + ".") || normalizedCandidate.hasSuffix("." + id) {
                return true
            }
        }
        return false
    }

    func matchesName(_ candidate: String) -> Bool {
        let normalizedCandidate = FileMatcher.normalize(candidate)
        return !normalizedCandidate.isEmpty && normalizedNames.contains(normalizedCandidate)
    }
}
