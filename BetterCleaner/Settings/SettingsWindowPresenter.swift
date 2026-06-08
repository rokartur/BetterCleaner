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
    }
}
