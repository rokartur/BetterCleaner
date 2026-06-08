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
    static var isGranted: Bool {
        BetterPermissions.isUsable(.fullDiskAccess)
    }

    /// Open the Full Disk Access pane in System Settings.
    static func openSettings() {
        BetterPermissions.openSettings(for: .fullDiskAccess)
    }
}
