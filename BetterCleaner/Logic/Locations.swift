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

    /// (category, subpath, depth, resolvesContainerID, autoSelectable). Shared by
    /// both domains.
    private static let subdirs: [(String, String, Int, Bool, Bool)] = [
        // Depth 3 (not 2) so strong com.<vendor>.* files nested under shared
        // containers — com.apple.sharedfilelist/…, CorePatch/Keychain/… — are
        // caught. Weak vendor-name matching stays capped at 2 levels (see scan).
        ("Application Support", "Application Support", 3, false, true),
        ("Application Support", "Application Support/CrashReporter", 1, false, true),
        ("Caches", "Caches", 2, false, true),
        ("Preferences", "Preferences", 1, false, true),
        ("Preferences", "Preferences/ByHost", 1, false, true),
        ("Containers", "Containers", 1, true, true),
        ("Group Containers", "Group Containers", 1, true, true),
        ("Logs", "Logs", 2, false, true),
        ("Crash Reports", "Logs/DiagnosticReports", 1, false, true),
        ("Saved Application State", "Saved Application State", 1, false, true),
        ("Autosave Information", "Autosave Information", 1, false, true),
        ("Cookies", "Cookies", 1, false, true),
        ("HTTPStorages", "HTTPStorages", 1, false, true),
        ("WebKit", "WebKit", 1, false, true),
        ("LaunchAgents", "LaunchAgents", 1, false, true),
        ("Application Scripts", "Application Scripts", 1, false, true),
        ("Internet Plug-Ins", "Internet Plug-Ins", 1, false, true),
        ("PreferencePanes", "PreferencePanes", 1, false, true),
        ("Services", "Services", 1, false, true),
        // Plug-in / component surfaces an app (or its installer) can drop into.
        ("Audio Plug-Ins", "Audio/Plug-Ins", 2, false, true),
        ("Screen Savers", "Screen Savers", 1, false, true),
        ("Color Pickers", "ColorPickers", 1, false, true),
        ("Input Methods", "Input Methods", 1, false, true),
        ("Spotlight", "Spotlight", 1, false, true),
        ("QuickLook", "QuickLook", 1, false, true),
        ("Contextual Menu Items", "Contextual Menu Items", 1, false, true),
        ("Address Book Plug-Ins", "Address Book Plug-Ins", 1, false, true),
        ("Mail Bundles", "Mail/Bundles", 1, false, true),
        ("Automator", "Automator", 1, false, true),
        ("Dictionaries", "Dictionaries", 1, false, true),
        ("Sounds", "Sounds", 1, false, true),
        ("Developer", "Developer", 1, false, true),
        // Fonts rarely carry a bundle id / app name, so a match here is weak —
        // surfaced but never auto-selected.
        ("Fonts", "Fonts", 1, false, false),
    ]

    /// System Library additionally exposes daemon + helper directories.
    private static let systemOnly: [(String, String, Int, Bool, Bool)] = [
        ("LaunchDaemons", "LaunchDaemons", 1, false, true),
        ("PrivilegedHelperTools", "PrivilegedHelperTools", 1, false, true),
        ("Extensions", "Extensions", 1, false, true),
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
        "Audio Plug-Ins", "Screen Savers", "Color Pickers", "Input Methods",
        "Spotlight", "QuickLook", "Contextual Menu Items", "Address Book Plug-Ins",
        "Mail Bundles", "Automator", "Dictionaries", "Sounds", "Developer",
        "Fonts", "Home", "Temporary", "Found by Spotlight",
        "Orphans (High confidence)", "Orphans (Medium confidence)", "Orphans (Low confidence)",
    ]

    private static func build(root: URL, entries: [(String, String, Int, Bool, Bool)], domain: FileDomain) -> [LibraryLocation] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [LibraryLocation] = []
        for (category, sub, depth, resolves, autoSelectable) in entries {
            let url = root.appendingPathComponent(sub, isDirectory: true)
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { continue }
            seen.insert(key)
            result.append(LibraryLocation(category: category, url: url, domain: domain, depth: depth, resolvesContainerID: resolves, autoSelectable: autoSelectable))
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
        var result: [LibraryLocation] = []
        func add(_ loc: LibraryLocation) {
            if fm.fileExists(atPath: loc.url.path) { result.append(loc) }
        }
        // Home root — hidden (dot) entries only.
        add(LibraryLocation(category: "Home", url: home, domain: .user, depth: 1, hiddenLeftoversOnly: true))
        // XDG-style config/cache/data roots: match the app's own subdirectory.
        add(LibraryLocation(category: "Configuration", url: home.appendingPathComponent(".config", isDirectory: true), domain: .user, depth: 1))
        add(LibraryLocation(category: "Caches", url: home.appendingPathComponent(".cache", isDirectory: true), domain: .user, depth: 1))
        add(LibraryLocation(category: "Application Support", url: home.appendingPathComponent(".local/share", isDirectory: true), domain: .user, depth: 1))
        // World temp (`/tmp` → `/private/tmp`): app sockets / state files.
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
