import Foundation

/// Scans developer cache directories and groups existing ones by environment.
/// All results default to unselected (deletion is destructive but recoverable
/// from the Trash within the session).
enum DevEnvironmentScanner {
    static func scan() -> [ScanSection] {
        let fm = FileManager.default

        // Expand glob entries (`~/.nvm/versions/node/*`, `…/AndroidStudio*`, …)
        // into concrete paths, then drop exact duplicates so overlapping catalog
        // entries can't double-count. Trailing slashes are normalized for the
        // dedupe key only.
        var locations: [DevLocation] = []
        var seen = Set<String>()
        for loc in DevLocations.all() {
            let paths = loc.path.contains("*") ? DevGlob.expand(loc.path) : [loc.path]
            for p in paths {
                let key = p.hasSuffix("/") ? String(p.dropLast()) : p
                guard seen.insert(key).inserted else { continue }
                locations.append(DevLocation(category: loc.category, path: p, tier: loc.tier))
            }
        }

        // Each dev cache (DerivedData, ~/.gradle, ~/.cargo, npm caches, …) is a
        // big independent tree whose recursive size walk dominates; size them
        // concurrently, one slot per location (index writes are data-race-free).
        var slots = [FileItem?](repeating: nil, count: locations.count)
        slots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: locations.count) { i in
                let location = locations[i]
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: location.path, isDirectory: &isDir) else { return }
                let url = URL(fileURLWithPath: location.path)
                let (size, complete) = FileSize.sizeWithStatus(of: url)
                guard size > 0 else { return }
                buffer[i] = FileItem(
                    url: url,
                    category: location.category,
                    domain: .user,
                    isDirectory: isDir.boolValue,
                    size: size,
                    isSelected: false,
                    sizeIsApproximate: !complete,
                    // `askFirst` artifacts (gems, local Maven/Gradle/Cargo repos) are
                    // never swept by Select All — only ticked deliberately.
                    isAutoSelectable: location.tier == .safeCache
                )
            }
        }

        // Merge in catalog order (preserves the original grouping order).
        var grouped: [String: [FileItem]] = [:]
        for case let item? in slots {
            grouped[item.category, default: []].append(item)
        }

        // Stale simulators (devices on a runtime that's no longer available) — the
        // biggest single dev reclaim and safe to drop, since they can't be booted.
        for item in staleSimulatorItems(fm: fm) {
            grouped[item.category, default: []].append(item)
        }

        return grouped
            .map { ScanSection(category: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.totalSize > $1.totalSize }
    }

    /// Simulator devices whose runtime is no longer available (`isAvailable ==
    /// false`) — dead weight under `~/Library/Developer/CoreSimulator/Devices` that
    /// `simctl delete unavailable` would prune. We surface each device folder so it
    /// goes through the recoverable Trash path instead of an irreversible delete, and
    /// label it with the resolved device + runtime name (the folder itself is a raw
    /// UUID). Auto-selectable: a device on a removed runtime can't be booted again.
    /// Requires Xcode command-line tools; absent or no Xcode → returns [].
    private static func staleSimulatorItems(fm: FileManager) -> [FileItem] {
        let devicesRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard fm.fileExists(atPath: devicesRoot.path),
              let xcrun = CommandRunner.firstExecutable(["/usr/bin/xcrun"]) else { return [] }

        let out = CommandRunner.run(xcrun, ["simctl", "list", "-j", "devices"])
        guard out.ok, let data = out.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any] else { return [] }

        var items: [FileItem] = []
        for (runtime, list) in byRuntime {
            guard let devices = list as? [[String: Any]] else { continue }
            let runtimeName = runtime
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .replacingOccurrences(of: "-", with: " ")
            for device in devices {
                // `isAvailable == false` (often with an availabilityError) means the
                // runtime was removed — the device can never boot. Available devices
                // are left untouched.
                let available = device["isAvailable"] as? Bool ?? true
                guard !available, let udid = device["udid"] as? String else { continue }
                let url = devicesRoot.appendingPathComponent(udid, isDirectory: true)
                guard fm.fileExists(atPath: url.path) else { continue }
                let (size, complete) = FileSize.sizeWithStatus(of: url)
                guard size > 0 else { continue }
                let name = device["name"] as? String ?? udid
                items.append(FileItem(
                    url: url,
                    category: "Simulators",
                    domain: .user,
                    isDirectory: true,
                    size: size,
                    isSelected: false,
                    sizeIsApproximate: !complete,
                    isAutoSelectable: true,
                    title: "\(name) · \(runtimeName) (unavailable)"
                ))
            }
        }
        return items
    }
}
