import Foundation

/// One scannable Library directory plus how to scan it.
struct LibraryLocation {
    let category: String
    let url: URL
    let domain: FileDomain
    /// How many levels of children to walk when matching. `1` = immediate
    /// children only; `2` descends into non-matching folders one extra level so
    /// vendor-grouped data (e.g. `Application Support/Google/Chrome`) is found.
    let depth: Int
    /// When true the scanner also reads each subfolder's sandbox metadata to map
    /// UUID-named containers back to their bundle id.
    let resolvesContainerID: Bool
    /// When false, matches here are never swept by "Select All" (e.g. Fonts and
    /// per-user temp dirs, where a stray name match would be costly to undo).
    let autoSelectable: Bool
    /// When true the directory is walked with hidden entries VISIBLE, but only
    /// dot-prefixed entries are considered. Used for the home root, where app
    /// leftovers are dot-directories (`~/.cmuxterm`) while a non-hidden `~/cmux`
    /// is almost always a user project the scan must not touch.
    let hiddenLeftoversOnly: Bool

    init(category: String, url: URL, domain: FileDomain, depth: Int = 1, resolvesContainerID: Bool = false, autoSelectable: Bool = true, hiddenLeftoversOnly: Bool = false) {
        self.category = category
        self.url = url
        self.domain = domain
        self.depth = depth
        self.resolvesContainerID = resolvesContainerID
        self.autoSelectable = autoSelectable
        self.hiddenLeftoversOnly = hiddenLeftoversOnly
    }
}

/// Catalog of the Library directories BetterCleaner scans for leftover files.
///
/// Coverage is deliberately comprehensive — every standard macOS location an app
/// (or its helpers) writes to — rather than a literal whole-disk walk, which is
/// slow, mostly empty, and dangerous. Sandbox containers are resolved by metadata
/// so UUID-named folders are matched, and high-traffic roots are walked two levels
/// deep to catch vendor-grouped data.
enum Locations {
    static var userLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    }

    static let systemLibrary = URL(fileURLWithPath: "/Library", isDirectory: true)

    private struct LocationSpec {
        let category: String
        let subpath: String
        let depth: Int
        let resolvesContainerID: Bool
        let autoSelectable: Bool

        init(_ category: String, _ subpath: String, _ depth: Int,
             resolvesContainerID: Bool = false, autoSelectable: Bool = true) {
            self.category = category
            self.subpath = subpath
            self.depth = depth
            self.resolvesContainerID = resolvesContainerID
            self.autoSelectable = autoSelectable
        }
    }

    private static let subdirs: [LocationSpec] = [
        // Depth 3 reaches bundle-id files nested under shared containers such as
        // com.apple.sharedfilelist. Depth 4 measured 40% slower with no extra hits.
        LocationSpec("Application Support", "Application Support", 3),
        LocationSpec("Application Support", "Application Support/CrashReporter", 1),
        LocationSpec("Caches", "Caches", 2),
        LocationSpec("Preferences", "Preferences", 1),
        LocationSpec("Preferences", "Preferences/ByHost", 1),
        LocationSpec("Containers", "Containers", 1, resolvesContainerID: true),
        LocationSpec("Group Containers", "Group Containers", 1, resolvesContainerID: true),
        LocationSpec("Logs", "Logs", 2),
        LocationSpec("Crash Reports", "Logs/DiagnosticReports", 1),
        LocationSpec("Saved Application State", "Saved Application State", 1),
        LocationSpec("Autosave Information", "Autosave Information", 1),
        LocationSpec("Cookies", "Cookies", 1),
        LocationSpec("HTTPStorages", "HTTPStorages", 1),
        LocationSpec("WebKit", "WebKit", 1),
        LocationSpec("LaunchAgents", "LaunchAgents", 1),
        LocationSpec("Application Scripts", "Application Scripts", 1),
        LocationSpec("Internet Plug-Ins", "Internet Plug-Ins", 1),
        LocationSpec("PreferencePanes", "PreferencePanes", 1),
        LocationSpec("Services", "Services", 1),
        LocationSpec("Audio Plug-Ins", "Audio/Plug-Ins", 2),
        LocationSpec("Components", "Components", 1),
        LocationSpec("Filesystems", "Filesystems", 1),
        // Depth 1: a framework is removed whole, and level 2 is the inside of
        // another vendor's bundle.
        LocationSpec("Frameworks", "Frameworks", 1),
        LocationSpec("Keyboard Layouts", "Keyboard Layouts", 1),
        LocationSpec("PDF Services", "PDF Services", 1),
        LocationSpec("Scripting Additions", "ScriptingAdditions", 1),
        LocationSpec("Startup Items", "StartupItems", 1),
        LocationSpec("Widgets", "Widgets", 1),
        LocationSpec("Screen Savers", "Screen Savers", 1),
        LocationSpec("Color Pickers", "ColorPickers", 1),
        LocationSpec("Input Methods", "Input Methods", 1),
        LocationSpec("Spotlight", "Spotlight", 1),
        LocationSpec("QuickLook", "QuickLook", 1),
        LocationSpec("Contextual Menu Items", "Contextual Menu Items", 1),
        LocationSpec("Address Book Plug-Ins", "Address Book Plug-Ins", 1),
        LocationSpec("Mail Bundles", "Mail/Bundles", 1),
        LocationSpec("Automator", "Automator", 1),
        LocationSpec("Dictionaries", "Dictionaries", 1),
        LocationSpec("Sounds", "Sounds", 1),
        LocationSpec("Developer", "Developer", 1),
        LocationSpec("Fonts", "Fonts", 1, autoSelectable: false),
    ]

    private static let systemOnly: [LocationSpec] = [
        LocationSpec("LaunchDaemons", "LaunchDaemons", 1),
        LocationSpec("PrivilegedHelperTools", "PrivilegedHelperTools", 1),
        LocationSpec("Extensions", "Extensions", 1),
    ]

    /// Unix tool prefixes outside `~/Library` that pkg/brew installers drop CLI
    /// binaries and shell-completion scripts into — e.g. `/usr/local/bin/mullvad`,
    /// `/usr/local/share/zsh/site-functions/_mullvad`, `mullvad.fish`. macOS's own
    /// uninstall scripts list these, but a Library-only scan misses them (the
    /// completion symlink is a documented un-removed leftover). Always scanned
    /// (not gated on includeSystem); matched by the same tight bundle-id/name/
    /// vendor rules, so only the app's own entries among many tools are taken.
    /// `(category, absolutePath, depth)`.
    private static let unixToolDirs: [(String, String, Int)] = [
        ("Command Line Tools", "/usr/local/bin", 1),
        ("Command Line Tools", "/usr/local/sbin", 1),
        ("Command Line Tools", "/opt/homebrew/bin", 1),
        ("Command Line Tools", "/opt/homebrew/sbin", 1),
        ("Shell Completions", "/usr/local/share/zsh/site-functions", 1),
        ("Shell Completions", "/usr/local/share/fish/vendor_completions.d", 1),
        ("Shell Completions", "/usr/local/share/bash-completion/completions", 1),
        ("Shell Completions", "/opt/homebrew/share/zsh/site-functions", 1),
        ("Shell Completions", "/opt/homebrew/share/fish/vendor_completions.d", 1),
        ("Shell Completions", "/opt/homebrew/share/bash-completion/completions", 1),
    ]

    /// Daemon settings + logs a pkg installer writes outside Library
    /// (`/etc/<vendor>`, `/var/log/<vendor>` — e.g. `/etc/mullvad-vpn`,
    /// `/var/log/mullvad-vpn`). System-owned, so scanned only with includeSystem
    /// and removed with admin rights. Depth 1 + tight matching keeps the scan off
    /// unrelated system config. `(category, absolutePath, depth)`.
    private static let systemDataDirs: [(String, String, Int)] = [
        ("Configuration", "/private/etc", 1),
        ("Logs", "/private/var/log", 1),
    ]

    static let categoryOrder: [String] = [
        "Application",
        "Application Support", "Caches", "Preferences", "Containers",
        "Group Containers", "Logs", "Crash Reports", "Saved Application State",
        "Autosave Information", "Cookies", "HTTPStorages", "WebKit",
        "LaunchAgents", "LaunchDaemons", "Application Scripts",
        "Internet Plug-Ins", "PreferencePanes", "PrivilegedHelperTools",
        "Services", "Extensions", "Configuration", "Receipts", "Package Files",
        "Command Line Tools", "Shell Completions",
        "Audio Plug-Ins", "Components", "Filesystems", "Frameworks",
        "Keyboard Layouts", "PDF Services", "Scripting Additions", "Startup Items",
        "Widgets", "Screen Savers", "Color Pickers", "Input Methods",
        "Spotlight", "QuickLook", "Contextual Menu Items", "Address Book Plug-Ins",
        "Mail Bundles", "Automator", "Dictionaries", "Sounds", "Developer",
        "Fonts", "Home", "Temporary", "Found by Spotlight",
        "Orphans (High confidence)", "Orphans (Medium confidence)", "Orphans (Low confidence)",
    ]

    private static func build(
        root: URL,
        entries: [LocationSpec],
        domain: FileDomain
    ) -> [LibraryLocation] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [LibraryLocation] = []
        for entry in entries {
            let url = root.appendingPathComponent(entry.subpath, isDirectory: true)
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { continue }
            seen.insert(key)
            result.append(LibraryLocation(
                category: entry.category,
                url: url,
                domain: domain,
                depth: entry.depth,
                resolvesContainerID: entry.resolvesContainerID,
                autoSelectable: entry.autoSelectable
            ))
        }
        return result
    }

    static func userLocations() -> [LibraryLocation] {
        build(root: userLibrary, entries: subdirs, domain: .user)
    }

    static func systemLocations() -> [LibraryLocation] {
        build(root: systemLibrary, entries: subdirs + systemOnly, domain: .system)
    }

    /// Build locations from absolute paths (not a Library subpath).
    private static func absolute(_ entries: [(String, String, Int)], domain: FileDomain) -> [LibraryLocation] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [LibraryLocation] = []
        for (category, path, depth) in entries {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { continue }
            seen.insert(key)
            result.append(LibraryLocation(category: category, url: url, domain: domain, depth: depth))
        }
        return result
    }

    /// CLI binaries + shell completions under `/usr/local` and `/opt/homebrew`.
    /// Marked system-domain (often root-owned); `Trasher` escalates only if a real
    /// permission error occurs, so user-owned brew files still move without a prompt.
    static func unixToolLocations() -> [LibraryLocation] { absolute(unixToolDirs, domain: .system) }

    /// `/etc` + `/var/log` daemon settings/logs (system-owned).
    static func systemDataLocations() -> [LibraryLocation] { absolute(systemDataDirs, domain: .system) }

    static func locations(includeSystem: Bool) -> [LibraryLocation] {
        // Unix tool dirs are always scanned — a CLI/completion leftover shouldn't
        // depend on the "include system files" toggle. `/etc` + `/var/log` are
        // genuinely system config, so they stay behind it.
        var locs = userLocations() + unixToolLocations()
        if includeSystem { locs += systemLocations() + systemDataLocations() }
        return locs
    }

    /// Per-user temporary roots that aren't fixed paths: the Darwin per-user
    /// cache/temp dirs under `/var/folders/...` and `$TMPDIR`. Apps drop
    /// bundle-id-named subfolders here. Resolved via `confstr` (no shell).
    /// Auto-selected like the rest: on uninstall the app is gone, so its temp
    /// data won't regenerate, and only entries matched to the app are surfaced.
    static func perUserTempLocations() -> [LibraryLocation] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [LibraryLocation] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard !seen.contains(url.path), fm.fileExists(atPath: url.path) else { return }
            seen.insert(url.path)
            result.append(LibraryLocation(category: "Temporary", url: url, domain: .user, depth: 1, resolvesContainerID: false, autoSelectable: true))
        }
        add(confstrPath(_CS_DARWIN_USER_CACHE_DIR))
        add(confstrPath(_CS_DARWIN_USER_TEMP_DIR))
        add(ProcessInfo.processInfo.environment["TMPDIR"])
        return result
    }

    /// App leftovers outside `~/Library`: dot-directories in the home root
    /// (`~/.cmuxterm`), XDG config/cache/data dirs (`~/.config/cmux`,
    /// `~/.cache/<app>`, `~/.local/share/<app>`), and world-temp socket/state files
    /// (`/private/tmp/<app>-*`) — places CLIs and cross-platform apps write that the
    /// `~/Library` catalog never reaches. The home root is scanned dot-only (a
    /// non-hidden `~/<name>` is a user project, not a leftover); every entry is
    /// matched by the same tight bundle-id/name/vendor rules, so only the removed
    /// app's own entries are surfaced. Depth 1 + tight matching keeps it off
    /// `~/.ssh`, `~/.zshrc`, and unrelated `/tmp` files.
    static func homeLeftoverLocations() -> [LibraryLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        var result: [LibraryLocation] = []
        var seen = Set<String>()
        func add(_ loc: LibraryLocation) {
            let path = loc.url.standardizedFileURL.path
            if seen.insert(path).inserted, fm.fileExists(atPath: path) { result.append(loc) }
        }
        // The XDG spec already requires these to be absolute paths and to be
        // ignored otherwise; enforced here, plus a containment check, because the
        // value becomes an auto-selectable scan root — an inherited
        // `XDG_DATA_HOME=/` would point the walk at the whole filesystem.
        let homePath = home.standardizedFileURL.path
        func xdg(_ variable: String, fallback: String, category: String) {
            let override = environment[variable].flatMap { value -> String? in
                guard value.hasPrefix("/") else { return nil }
                let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
                return standardized.hasPrefix(homePath + "/") ? standardized : nil
            }
            let path = override ?? home.appendingPathComponent(fallback, isDirectory: true).path
            add(LibraryLocation(
                category: category,
                url: URL(fileURLWithPath: path, isDirectory: true),
                domain: .user,
                depth: 1
            ))
        }

        add(LibraryLocation(category: "Home", url: home, domain: .user, depth: 1, hiddenLeftoversOnly: true))
        xdg("XDG_CONFIG_HOME", fallback: ".config", category: "Configuration")
        xdg("XDG_CACHE_HOME", fallback: ".cache", category: "Caches")
        xdg("XDG_DATA_HOME", fallback: ".local/share", category: "Application Support")
        xdg("XDG_STATE_HOME", fallback: ".local/state", category: "Application Support")
        add(LibraryLocation(
            category: "Application Support",
            url: home.appendingPathComponent(".var/app", isDirectory: true),
            domain: .user,
            depth: 1
        ))
        add(LibraryLocation(category: "Temporary", url: URL(fileURLWithPath: "/private/tmp", isDirectory: true), domain: .user, depth: 1))
        return result
    }

    private static func confstrPath(_ name: Int32) -> String? {
        let len = confstr(name, nil, 0)
        // `len` includes the trailing null; bound it and allocate one extra byte
        // so a fully-populated buffer always stays null-terminated.
        guard len > 0, len < 8192 else { return nil }
        var buf = [CChar](repeating: 0, count: len + 1)
        guard confstr(name, &buf, len + 1) > 0 else { return nil }
        return String(cString: buf)
    }
}
