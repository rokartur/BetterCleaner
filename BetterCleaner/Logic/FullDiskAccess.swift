import AppKit
import BetterPermissions

/// Detects and helps the user grant Full Disk Access — required to scan the
/// TCC-protected parts of `~/Library` (a non-sandboxed app still needs FDA to
/// read e.g. Containers, Safari, Mail).
///
/// Backed by `BetterPermissions`, which owns the status probe and the System
/// Settings deep-link; this stays a thin façade so existing call sites keep the
/// same `FullDiskAccess.isGranted` / `FullDiskAccess.openSettings()` shape.
@MainActor
enum FullDiskAccess {
    /// `true` when Full Disk Access is granted and usable right now.
    ///
    /// Reads `BetterPermissions`' write-through cache. The cache is only refreshed
    /// when an observer arms the change detector — which the app never does — so
    /// after the first probe this value is frozen for the process lifetime. Call
    /// `refresh()` after the user may have toggled the grant in System Settings.
    static var isGranted: Bool {
        BetterPermissions.isUsable(.fullDiskAccess)
    }

    /// Force a fresh probe of the TCC database and return the current grant state.
    /// Use this when re-checking after the app regains focus, since `isGranted`
    /// otherwise returns a stale cached value.
    @discardableResult
    static func refresh() -> Bool {
        BetterPermissions.refresh(.fullDiskAccess).status.isUsable
    }

    /// Open the Full Disk Access pane in System Settings.
    static func openSettings() {
        BetterPermissions.openSettings(for: .fullDiskAccess)
    }

    /// Make the app appear in the Full Disk Access list with a switch to toggle.
    ///
    /// macOS only lists an app under Full Disk Access once it has *attempted* to
    /// reach an FDA-protected resource — a denied attempt is enough to register it.
    /// Without this the deep-link opens an empty pane and there's nothing to flip.
    /// Reading a couple of protected paths (results ignored) forces the registration.
    static func provokeRegistration() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let protectedPaths = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Mail",
        ]
        for rel in protectedPaths {
            let url = home.appendingPathComponent(rel)
            _ = try? Data(contentsOf: url, options: .mappedIfSafe)
            _ = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
    }
}
