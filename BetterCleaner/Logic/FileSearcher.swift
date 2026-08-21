import Foundation

/// System-wide file search over two engines, mapping hits to `FileItem` rows the
/// shared file list can review and trash.
///
/// By name, Spotlight answers instantly but only covers indexed volumes and skips
/// most hidden/system trees. By contents, `rg` greps the files themselves — no
/// index, so it sees whatever it can read, at the cost of a real walk. Hits are
/// never auto-selectable: these are the user's own files, not identified junk.
enum FileSearcher {
    static let category = "Search Results"
    /// Hits are taken up to this many and no further: a two-letter name query
    /// matches a quarter-million paths on a normal Mac, and every kept hit pays a
    /// size walk.
    static let resultLimit = 500
    /// Ceiling on one content grep: a whole-Mac walk has no natural end, and
    /// partial results now beat complete results in five minutes.
    static let contentSearchTimeout: TimeInterval = 30
    /// Ceiling on measuring the hits, which recursively walks every directory among
    /// them. Rows are worth more than exact sizes; past this they read "approximate".
    static let sizingTimeout: TimeInterval = 10
    /// Files larger than this are not grepped: a disk image or a database is not
    /// what "search inside my files" means, and reading one costs the whole budget.
    static let maxGrepFileSizeMB = 50

    /// What the search text is matched against.
    enum Match: CaseIterable {
        case name, contents

        var title: String { self == .name ? "Match Name" : "Match Contents" }
    }

    enum Kind: CaseIterable {
        case any, applications, folders, documents, images, movies, audio, archives

        var title: String {
            switch self {
            case .any:          return "Any Kind"
            case .applications: return "Applications"
            case .folders:      return "Folders"
            case .documents:    return "Documents"
            case .images:       return "Images"
            case .movies:       return "Movies"
            case .audio:        return "Audio"
            case .archives:     return "Archives"
            }
        }

        /// Uniform Type Identifier every member of this kind conforms to.
        var contentType: String? {
            switch self {
            case .any:          return nil
            case .applications: return "com.apple.application"
            case .folders:      return "public.folder"
            case .documents:    return "public.content"
            case .images:       return "public.image"
            case .movies:       return "public.movie"
            case .audio:        return "public.audio"
            case .archives:     return "public.archive"
            }
        }
    }

    /// Case order drives the picker; `everywhere` leads because it is the default.
    enum Scope: CaseIterable {
        case everywhere, home

        var title: String { self == .home ? "Home Folder" : "This Mac" }

        var root: URL? {
            self == .home ? FileManager.default.homeDirectoryForCurrentUser : nil
        }
    }

    struct Criteria: Equatable {
        var text = ""
        var match = Match.name
        var kind = Kind.any
        /// Minimum on-disk size in bytes; 0 = no size filter.
        var minSize: Int64 = 0
        /// Changed within the last N days; 0 = any date.
        var withinDays = 0
        var scope = Scope.everywhere
        /// Content search only: also grep files a `.gitignore` excludes.
        var includeIgnoredFiles = false

        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// Content search has nothing to grep for without text; name search can run
        /// on the pickers alone ("every app over 1 GB").
        var isEmpty: Bool {
            guard match == .name else { return trimmedText.isEmpty }
            return trimmedText.isEmpty && kind == .any && minSize == 0 && withinDays == 0
        }
    }

    /// Content search needs ripgrep; without it the picker must say so rather than
    /// quietly return nothing.
    static var ripgrepPath: String? {
        CommandRunner.firstExecutable([
            "/opt/homebrew/bin/rg",     // Apple Silicon Homebrew
            "/usr/local/bin/rg",        // Intel Homebrew
            "/usr/bin/rg",
        ])
    }

    /// Build the `mdfind` query. Text starting with `kMDItem` is passed through
    /// verbatim, so the field doubles as a raw Spotlight query box for anyone who
    /// knows the syntax. Returns nil when nothing was asked for — an unfiltered
    /// query would return the whole index.
    static func query(for criteria: Criteria) -> String? {
        let text = criteria.trimmedText

        var predicates: [String] = []
        if !text.isEmpty {
            // A raw predicate stands in for the name clause rather than replacing the
            // whole query, so the pickers keep working next to it.
            predicates.append(text.hasPrefix("kMDItem")
                ? text
                : "kMDItemFSName == \"*\(SpotlightScanner.escapeQueryValue(text))*\"cd")
        }
        if let tree = criteria.kind.contentType {
            predicates.append("kMDItemContentTypeTree == \"\(tree)\"")
        }
        if criteria.minSize > 0 { predicates.append("kMDItemFSSize >= \(criteria.minSize)") }
        if criteria.withinDays > 0 {
            predicates.append("kMDItemFSContentChangeDate >= $time.today(-\(criteria.withinDays))")
        }
        guard !predicates.isEmpty else { return nil }
        return predicates.map { "(\($0))" }.joined(separator: " && ")
    }

    /// What one search produced. `truncated` means the list is only part of what
    /// matched — cut off at `resultLimit`, or by the content-search timeout — so the
    /// UI must never report an empty result as "nothing matches".
    struct Results {
        var items: [FileItem] = []
        var truncated = false
        /// Size of the hits, counting a matched folder's bytes once even when files
        /// inside it matched too.
        var totalSize: Int64 = 0
        /// ripgrep rejected the pattern (its exit code 2), which is a typo in the
        /// user's regex, not an absence of matches.
        var invalidPattern = false
    }

    static func search(
        _ criteria: Criteria,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Results {
        guard !criteria.isEmpty, !isCancelled() else { return Results() }

        let found: (paths: [String], truncated: Bool, invalidPattern: Bool)
        switch criteria.match {
        case .name:
            guard let query = query(for: criteria) else { return Results() }
            let paths = SpotlightScanner
                .mdfindPaths(query, onlyIn: criteria.scope.root, isCancelled: isCancelled)
                .map(\.path)
            found = (paths, false, false)
        case .contents:
            found = grepPaths(criteria, isCancelled: isCancelled)
        }
        guard !isCancelled() else { return Results() }
        guard !found.invalidPattern else { return Results(invalidPattern: true) }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // Bounded before anything per-path runs: a broad query returns hundreds of
        // thousands of paths, and sizing or nesting-checking them all would hang.
        var kept: [String] = []
        var truncated = found.truncated
        for path in found.paths where isReviewable(path) {
            // Only ripgrep hits need the size/date filters applied here, and doing it
            // inside the cap keeps a broad grep from stat-ing 100k paths it will
            // never show.
            if criteria.match == .contents, !matchesFilters(URL(fileURLWithPath: path), criteria) { continue }
            if kept.count == resultLimit { truncated = true; break }
            kept.append(path)
        }

        // A hit can be any directory on the disk — node_modules, a Time Machine
        // volume — and sizing one is a full recursive walk, so the sizing phase gets
        // its own deadline. Past it, rows still appear, with sizes marked approximate.
        let sizingDeadline = Date().addingTimeInterval(sizingTimeout)
        let stopSizing = { isCancelled() || Date() >= sizingDeadline }

        let fm = FileManager.default
        let items = kept.compactMap { path -> FileItem? in
            guard !isCancelled() else { return nil }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let url = URL(fileURLWithPath: path)
            // A plain file's size is one stat, so it is always measured; only the
            // recursive directory walk answers to the deadline.
            let size = isDirectory.boolValue
                ? FileSize.sizeWithStatus(of: url, isCancelled: stopSizing)
                : FileSize.sizeWithStatus(of: url, isCancelled: isCancelled)
            return FileItem(
                url: url,
                category: category,
                domain: path.hasPrefix(home + "/") ? .user : .system,
                isDirectory: isDirectory.boolValue,
                size: size.bytes,
                sizeIsApproximate: !size.complete,
                // Arbitrary user files: surfaced for review, never bulk-selected.
                isAutoSelectable: false
            )
        }
        guard !isCancelled() else { return Results() }

        // Every hit stays visible — a search for "config" must still show
        // config/config.json — but nested hits do not double-count in the total.
        let topLevel = Set(ScanExclusions.topLevelPaths(items.map(\.url.path)))
        return Results(
            items: items,
            truncated: truncated,
            totalSize: items.filter { topLevel.contains($0.url.path) }.reduce(0) { $0 + $1.size }
        )
    }

    /// Grep file contents with ripgrep. Reports whether the run was cut short by
    /// `contentSearchTimeout`, and whether ripgrep rejected the pattern.
    private static func grepPaths(
        _ criteria: Criteria,
        isCancelled: @escaping () -> Bool
    ) -> (paths: [String], truncated: Bool, invalidPattern: Bool) {
        guard let ripgrep = ripgrepPath else { return ([], false, false) }

        let arguments = [
            "--files-with-matches",
            "--smart-case",
            "--hidden",             // dotfiles are exactly what people grep for
            "--glob", "!.git/",
            "--max-filesize", "\(maxGrepFileSizeMB)M",
            "--no-messages",        // an unreadable folder is not an error here
            "--no-config",          // the user's RIPGREP_CONFIG_PATH must not alter output
            "--null",
            // Without this ripgrep block-buffers into a pipe, so the SIGTERM at the
            // deadline would discard the last, usually only, unflushed block.
            "--line-buffered",
        ] + (criteria.includeIgnoredFiles ? ["--no-ignore"] : [])
            + ["--", criteria.trimmedText] + grepRoots(criteria.scope)

        let deadline = Date().addingTimeInterval(contentSearchTimeout)
        let output = CommandRunner.run(ripgrep, arguments) {
            isCancelled() || Date() >= deadline
        }
        guard !isCancelled() else { return ([], false, false) }

        // ripgrep exits 0 with matches, 1 without, and 2 when it could not run the
        // search at all — an unparseable regex, which must not read as "no matches".
        guard output.status != 2 else { return ([], false, true) }

        // A run killed at the deadline keeps the paths it already printed: the whole
        // point of the timeout is partial results now over complete results later.
        let timedOut = output.status == CommandRunner.cancelledStatus
        return (output.stdout.split(separator: "\0").map(String.init), timedOut, false)
    }

    /// Roots ripgrep walks. `everywhere` covers the mounted volumes and user-
    /// writable trees but skips the read-only OS at `/System` and the device tree:
    /// grepping those costs minutes and returns files no one can act on.
    private static func grepRoots(_ scope: Scope) -> [String] {
        guard scope == .everywhere else { return [FileManager.default.homeDirectoryForCurrentUser.path] }
        // Only roots whose hits can actually be acted on: anything `forbiddenRoots`
        // rejects would be walked at full cost and then dropped from the results.
        return ["/Users", "/Applications", "/Library", "/opt", "/private/var", "/Volumes"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Spotlight enforces the size and date pickers inside its query; ripgrep only
    /// knows about text, so its hits are held to the same filters here. Kind is not
    /// among them — it is disabled for content search rather than guessed at from a
    /// file extension that dotfiles do not have.
    private static func matchesFilters(_ url: URL, _ criteria: Criteria) -> Bool {
        guard criteria.minSize > 0 || criteria.withinDays > 0 else { return true }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if criteria.minSize > 0, Int64(values?.fileSize ?? 0) < criteria.minSize { return false }
        if criteria.withinDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(criteria.withinDays) * 86_400)
            guard let modified = values?.contentModificationDate, modified >= cutoff else { return false }
        }
        return true
    }

    /// Trees a search must never offer up for deletion, with everything inside them.
    /// Every other page reaches system paths only through an app-association filter;
    /// this one asks the whole disk, so the boot-critical directories are named here
    /// instead. Removing any of these breaks the machine, and `Trasher` would move
    /// them with admin rights on a single prompt.
    static let forbiddenRoots = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var/db",
        "/Library/Keychains", "/Library/LaunchDaemons", "/Library/LaunchAgents",
        "/Library/Extensions", "/Library/Security", "/Library/SystemExtensions",
    ]

    /// Container directories: a search finds their contents, but the container
    /// itself is never offered, because "move to Trash" applied to one of these is
    /// not a cleanup, it is an outage. Exact paths only — what lives inside stays
    /// reviewable.
    private static let undeletableContainers: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let systemLevel = [
            "/", "/Users", "/Users/Shared", "/Applications", "/Applications/Utilities",
            "/Library", "/opt", "/private", "/var", "/tmp", "/Volumes",
        ]
        // Losing ~/Documents, or every app's data in Application Support, is the same
        // class of accident as losing /Library itself.
        let userLevel = ["Library", "Documents", "Desktop", "Downloads", "Movies", "Music",
                         "Pictures", "Public", "Applications", "Developer"]
        let appData = ["Application Support", "Preferences", "Containers", "Group Containers",
                       "Caches", "Fonts", "PrivilegedHelperTools", "Keychains"]
        return Set(
            systemLevel + [home]
                + userLevel.map { home + "/" + $0 }
                + appData.flatMap { ["/Library/" + $0, home + "/Library/" + $0] }
        )
    }()

    /// Whether `path` is a single component under `container`, i.e. one of the
    /// entries that container exists to hold: a mounted volume, or a user's home.
    private static func isDirectChild(_ path: String, of container: String) -> Bool {
        path.hasPrefix(container + "/") && !path.dropFirst(container.count + 1).contains("/")
    }

    /// Paths the user could act on: boot-critical trees, whole containers and
    /// already-trashed items are not reviewable in a list whose only action is
    /// "move to Trash".
    static func isReviewable(_ rawPath: String) -> Bool {
        // Spotlight reports /etc and /var while ripgrep echoes the literal root it
        // walked, /private/etc. `standardizedFileURL` only collapses that prefix when
        // the shorter path exists, which is not a guarantee a deletion guard can rest
        // on, so the prefix is stripped here and every rule is written once.
        let path = rawPath.hasPrefix("/private/") ? String(rawPath.dropFirst("/private".count)) : rawPath
        guard !ScanExclusions.isInTrash(path) else { return false }
        guard !undeletableContainers.contains(path) else { return false }
        // A mounted volume and another account's home folder are containers too, and
        // neither can be enumerated ahead of time.
        guard !isDirectChild(path, of: "/Volumes"), !isDirectChild(path, of: "/Users") else { return false }
        guard !forbiddenRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return !FileMatcher.isProtected(url: URL(fileURLWithPath: path))
    }
}
