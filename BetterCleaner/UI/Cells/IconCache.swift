import AppKit

/// Process-wide cache of file/app icons keyed by absolute path.
///
/// `NSWorkspace.icon(forFile:)` reads and decodes the target's `.icns`
/// synchronously. The apps list and leftover-file list re-`configure` their
/// cells on every `reloadData` (search keystroke, checkbox toggle, scroll), so
/// without a cache each visible row re-decodes the same icon from disk on the
/// main thread. Bundle icons are stable within a session, so a path-keyed cache
/// is behavior-preserving. `NSCache` is itself thread-safe.
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}
