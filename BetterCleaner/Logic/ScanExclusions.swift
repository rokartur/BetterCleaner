import Foundation

/// User-defined paths to skip during scanning. A path is excluded when it equals
/// an entry exactly or sits anywhere beneath one (so excluding a folder skips its
/// whole subtree). Pure and side-effect free.
///
/// Exclusions only ever *skip* a candidate — they run after `FileMatcher.isProtected`
/// and never resurrect a protected file.
enum ScanExclusions {
    /// Whether `url` is excluded by `excluded` (a set of standardized paths).
    static func isExcluded(_ url: URL, in excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        if excluded.contains(path) { return true }
        for prefix in excluded where path.hasPrefix(prefix + "/") { return true }
        return false
    }

    /// Build the standardized-path set the scanners compare against.
    static func set(from urls: [URL]) -> Set<String> {
        Set(urls.map { $0.standardizedFileURL.path })
    }

    /// Whether `path` lives in a macOS Trash — the user's `~/.Trash` or a
    /// per-volume `/.Trashes`. Trashed items (including an app bundle BetterCleaner
    /// itself just moved to the Trash, which Spotlight keeps indexing at its new
    /// Trash path) are already on their way out, so scanners must never surface
    /// them as "installed" apps or "leftover" files.
    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}
