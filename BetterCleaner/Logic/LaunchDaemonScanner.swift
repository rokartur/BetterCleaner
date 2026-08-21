import Foundation

struct LaunchItem {
    let label: String
    let url: URL
    let domain: FileDomain
    let isAgent: Bool
    let isLoaded: Bool
    /// False for `/System/...` (SIP-protected, never removable).
    let isRemovable: Bool

    var id: String { url.path }
}

/// Lists LaunchAgents / LaunchDaemons and removes selected ones (trash the
/// plist; system ones via admin). Status comes from `launchctl list`.
enum LaunchDaemonScanner {
    private struct Dir { let path: String; let domain: FileDomain; let isAgent: Bool; let removable: Bool }

    private static func dirs() -> [Dir] {
        let home = NSHomeDirectory()
        return [
            Dir(path: home + "/Library/LaunchAgents", domain: .user, isAgent: true, removable: true),
            Dir(path: "/Library/LaunchAgents", domain: .system, isAgent: true, removable: true),
            Dir(path: "/Library/LaunchDaemons", domain: .system, isAgent: false, removable: true),
            Dir(path: "/System/Library/LaunchAgents", domain: .system, isAgent: true, removable: false),
            Dir(path: "/System/Library/LaunchDaemons", domain: .system, isAgent: false, removable: false),
        ]
    }

    static func loadedLabels() -> Set<String> {
        let out = CommandRunner.run("/bin/launchctl", ["list"])
        guard out.ok else { return [] }
        return parseLoadedLabels(out.stdout)
    }

    /// Parse `launchctl list` stdout → loaded labels. Columns are PID, Status,
    /// Label (tab-separated); the first line is the header and is skipped.
    static func parseLoadedLabels(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n").dropFirst() {
            if let label = line.split(separator: "\t").last { labels.insert(String(label)) }
        }
        return labels
    }

    static func scan(includeSystem: Bool) -> [LaunchItem] {
        let fm = FileManager.default
        let loaded = loadedLabels()
        var items: [LaunchItem] = []

        for dir in dirs() {
            if dir.path.hasPrefix("/System/") && !includeSystem { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir.path),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension == "plist" {
                let label = label(of: url) ?? url.deletingPathExtension().lastPathComponent
                items.append(LaunchItem(
                    label: label,
                    url: url,
                    domain: dir.domain,
                    isAgent: dir.isAgent,
                    isLoaded: loaded.contains(label),
                    isRemovable: dir.removable
                ))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// The sanitized launchd `Label` of a plist, or nil if missing/untrusted.
    /// Public so the uninstaller can `launchctl bootout` the job before deleting
    /// its plist (else the daemon respawns its files).
    static func label(of url: URL) -> String? {
        guard let plist = plist(of: url),
              let label = plist["Label"] as? String,
              // Reject untrusted Labels that could mislead the user (path traversal
              // / absolute paths). Fall back to the filename in scan().
              !label.isEmpty, !label.contains(".."), !label.hasPrefix("/")
        else { return nil }
        return label
    }

    /// The executable a launchd plist runs — `Program`, else the first element of
    /// `ProgramArguments`, else `BundleProgram`. Used by the orphan scanner to
    /// flag jobs whose program no longer exists on disk.
    static func programPath(of url: URL) -> String? {
        guard let plist = plist(of: url) else { return nil }
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty { return first }
        if let bundled = plist["BundleProgram"] as? String, !bundled.isEmpty { return bundled }
        return nil
    }

    private static func plist(of url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

}
