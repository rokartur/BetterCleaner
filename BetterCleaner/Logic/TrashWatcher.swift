import AppKit
import BetterPermissions
import UserNotifications

/// Watches the user's Trash and, when a `.app` bundle is dragged in — the common
/// "uninstall by dropping it in the Trash" path that never runs a cleaner — scans
/// for that app's leftover files and posts a notification offering to remove them.
///
/// Opt-in via `Preferences.watchTrashForLeftovers`. The watcher snapshots the
/// `.app`s already in the Trash at start, so it only reacts to newly-trashed apps.
@MainActor
final class TrashWatcher {
    static let shared = TrashWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var knownApps = Set<String>()
    private var debounce: DispatchWorkItem?

    private var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    private init() {}

    /// Start or stop watching to match the preference. Idempotent.
    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard source == nil else { return }
        let descriptor = open(trashURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fileDescriptor = descriptor
        knownApps = currentAppNames()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            // The source fires on the main queue, so we are already on the main actor.
            MainActor.assumeIsolated { self?.scheduleDiff() }
        }
        src.setCancelHandler { close(descriptor) }
        source = src
        src.resume()

        Task { await BetterPermissions.request(.notifications) }
    }

    private func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    /// A drag into the Trash emits several filesystem events; coalesce them before
    /// diffing so one trashed app yields one scan.
    private func scheduleDiff() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.diffAndScan() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func currentAppNames() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(entries.filter { $0.pathExtension == "app" }.map { $0.lastPathComponent })
    }

    private func diffAndScan() {
        let current = currentAppNames()
        let added = current.subtracting(knownApps)
        knownApps = current
        for name in added {
            handleTrashedApp(at: trashURL.appendingPathComponent(name, isDirectory: true))
        }
    }

    private func handleTrashedApp(at url: URL) {
        // Read identity straight from the bundle: AppFinder deliberately refuses
        // Trash paths (a trashed app isn't "installed"), so build the descriptor here.
        guard FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let trashedApp = InstalledApp(
            url: url,
            bundleID: bundle.bundleIdentifier,
            name: name,
            executable: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            isSystem: false
        )

        // Capture the (main-actor) preferences as plain values before going off-main.
        let sensitivity = Preferences.shared.searchSensitivity
        let includeSystem = Preferences.shared.includeSystemFiles

        DispatchQueue.global(qos: .utility).async {
            let others = AppFinder.installedApps()
            let items = LeftoverScanner.scan(
                app: trashedApp, sensitivity: sensitivity, includeSystem: includeSystem, otherApps: others)
            // Exclude the trashed bundle itself; count only the leftovers it left behind.
            let leftovers = items.filter { $0.category != "Application" }
            guard !leftovers.isEmpty else { return }
            let bytes = leftovers.reduce(Int64(0)) { $0 + $1.size }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.postLeftoverNotification(appName: name, count: leftovers.count, bytes: bytes)
                }
            }
        }
    }

    private func postLeftoverNotification(appName: String, count: Int, bytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) moved to Trash"
        content.body = "\(count) leftover item\(count == 1 ? "" : "s") · \(FileSize.string(bytes)) remain. "
            + "Open \(AppInfo.displayName) to review and remove them."
        let request = UNNotificationRequest(
            identifier: "trash-leftovers-\(appName)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
