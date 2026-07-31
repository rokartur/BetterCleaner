import AppKit
import BetterSettings

/// Shared entry point for the native (BetterSettings) settings window. Uses
/// `.releaseOnClose` so the window tree is freed on close and rebuilt on reopen.
@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private let presenter = SettingsPresenter(closeBehavior: .releaseOnClose) {
        SettingsCatalog.makeConfiguration()
    }

    private init() {}

    func show(selecting tabID: String? = nil) {
        NSApp.setActivationPolicy(.regular)
        presenter.show(selecting: tabID)
        restoreFrame()
    }

    private static let frameName = "BetterCleanerSettingsWindow"

    /// BetterSettings centers every freshly built window (and `.releaseOnClose`
    /// rebuilds it on each open), so re-apply the user's last position here.
    private func restoreFrame() {
        guard let window = NSApp.windows.first(where: { $0 is SettingsWindow }),
              window.frameAutosaveName.isEmpty else { return }
        let size = window.frame.size
        window.setFrameAutosaveName(Self.frameName)
        // force: the window is non-resizable, which plain restore skips.
        if window.setFrameUsingName(Self.frameName, force: true) {
            // Fixed-size window: keep the restored top-left, reassert the
            // current size in case a release changed the configured windowSize.
            var frame = window.frame
            frame.origin.y += frame.size.height - size.height
            frame.size = size
            window.setFrame(frame, display: false)
        }
    }
}
