import AppKit

/// Enumerates installed `.app` bundles and reads their identity.
enum AppFinder {
    static func defaultRoots() -> [URL] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        return roots.filter { fm.fileExists(atPath: $0.path) }
    }

    static func installedApps(extraRoots: [URL] = []) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<URL>()
        var apps: [InstalledApp] = []

        for root in defaultRoots() + extraRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension == "app" {
                let std = url.standardizedFileURL
                if seen.contains(std) { continue }
                seen.insert(std)
                if let app = app(at: std) { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Build an `InstalledApp` from a bundle URL, reading its identifier, name,
    /// executable, and the bundle ids of any nested helpers.
    static func app(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app" else { return nil }
        // Must be a real bundle directory that exists — guards against a deep-link
        // / Finder-extension path like "/tmp/fake.app" that isn't an app bundle.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        // A bundle in the Trash isn't "installed" — guard against a user-added
        // Trash scan root or a drag-drop / deep-link of an already-trashed app.
        if ScanExclusions.isInTrash(url.standardizedFileURL.path) { return nil }
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        let shortVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let isSystem = url.path.hasPrefix("/System/")
        let nested = nestedBundleIDs(in: url, excluding: bundleID)
        return InstalledApp(
            url: url,
            bundleID: bundleID,
            name: name,
            executable: executable,
            extraBundleIDs: nested,
            isSystem: isSystem,
            teamID: CodeSigning.teamID(of: url),
            shortVersion: shortVersion
        )
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
            if let b = app.bundleID?.lowercased(), !b.isEmpty { ids.insert(b) }
            for e in app.extraBundleIDs {
                let l = e.lowercased()
                if !l.isEmpty { ids.insert(l) }
            }
            let n = FileMatcher.normalize(app.name)
            if !n.isEmpty { names.insert(n) }
            if let exe = app.executable {
                let e = FileMatcher.normalize(exe)
                if !e.isEmpty { names.insert(e) }
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
        let c = candidate.lowercased()
        if bundleIDs.contains(c) { return true }
        for id in bundleIDs where !id.isEmpty {
            if c.hasPrefix(id + ".") || c.hasSuffix("." + id) { return true }
        }
        return false
    }

    func matchesName(_ candidate: String) -> Bool {
        let n = FileMatcher.normalize(candidate)
        return !n.isEmpty && normalizedNames.contains(n)
    }
}
