import Foundation

/// A matcher's view of an app: every signal used to find leftover files.
///
/// Beyond the primary bundle id + display name, this carries the executable name
/// (cache folders are often named after it) and any nested bundle ids harvested
/// from the app's login items / plug-ins / XPC services — so files dropped by an
/// app's helpers are attributed to the parent app.
struct AppDescriptor: Hashable {
    let bundleID: String?
    let name: String
    let executable: String?
    let extraBundleIDs: [String]
    /// Lowercased code-signing Team Identifier, when the app is signed. Ownership
    /// evidence used to reject look-alike leftovers from a different publisher.
    let teamID: String?
    /// Primary + nested bundle ids, lowercased, de-duplicated, in priority order.
    /// Computed once at init — it is read once per file (and again inside
    /// `vendorTokens`/`vendorNamespaces`) on the leftover-scan hot path, so the
    /// per-file recompute + O(n²) de-dup the computed property used was pure
    /// repeated allocation.
    let allBundleIDs: [String]

    init(bundleID: String?, name: String, executable: String? = nil, extraBundleIDs: [String] = [], teamID: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.executable = executable
        self.extraBundleIDs = extraBundleIDs
        self.teamID = teamID

        var ids: [String] = []
        var seen = Set<String>()
        if let b = bundleID?.lowercased(), !b.isEmpty { ids.append(b); seen.insert(b) }
        for e in extraBundleIDs {
            let l = e.lowercased()
            if !l.isEmpty, seen.insert(l).inserted { ids.append(l) }
        }
        self.allBundleIDs = ids
    }
}

/// An installed application discovered by `AppFinder`.
struct InstalledApp: Hashable, Identifiable {
    let url: URL
    let bundleID: String?
    let name: String
    /// `CFBundleExecutable` — frequently the name used for cache/support folders.
    let executable: String?
    /// Bundle ids of nested helpers (login items, plug-ins, XPC services).
    let extraBundleIDs: [String]
    /// True when the app lives under `/System` (read-only, never trashable).
    let isSystem: Bool
    /// Lowercased code-signing Team Identifier, when signed.
    let teamID: String?
    /// `CFBundleShortVersionString` — the user-facing version string, shown in the
    /// detail pane's hero header. `nil` when the bundle declares none.
    let shortVersion: String?

    init(
        url: URL,
        bundleID: String?,
        name: String,
        executable: String? = nil,
        extraBundleIDs: [String] = [],
        isSystem: Bool,
        teamID: String? = nil,
        shortVersion: String? = nil
    ) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.executable = executable
        self.extraBundleIDs = extraBundleIDs
        self.isSystem = isSystem
        self.teamID = teamID
        self.shortVersion = shortVersion
    }

    var id: URL { url }
    var descriptor: AppDescriptor {
        AppDescriptor(bundleID: bundleID, name: name, executable: executable, extraBundleIDs: extraBundleIDs, teamID: teamID)
    }
}
