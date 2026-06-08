import Foundation

enum FileSize {
    /// On-disk allocated size of a file or directory (recursive for directories).
    static func size(of url: URL) -> Int64 {
        sizeWithStatus(of: url).bytes
    }

    /// Allocated size plus whether the walk was *complete*. `complete == false`
    /// means at least one entry couldn't be read (permission, broken symlink,
    /// enumerator failure), so `bytes` is a lower bound. The plain `size(of:)`
    /// can't express this and reports `0` for an unreadable 2 GB folder — which
    /// for an uninstaller reads as "nothing here" and erodes trust. Callers that
    /// surface sizes to the user should prefer this and mark approximate totals.
    static func sizeWithStatus(of url: URL) -> (bytes: Int64, complete: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, true) }

        if !isDir.boolValue {
            return allocatedSize(url)
        }

        var total: Int64 = 0
        var complete = true
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        // errorHandler runs synchronously on this thread during enumeration, so
        // capturing `complete` is safe; returning true keeps walking past the
        // failed entry instead of aborting the whole directory.
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in complete = false; return true }
        ) else { return (0, false) }

        for case let fileURL as URL in enumerator {
            let (bytes, ok) = allocatedSize(fileURL)
            total += bytes
            if !ok { complete = false }
        }
        return (total, complete)
    }

    /// (allocated bytes, readable). `readable == false` when resource values
    /// can't be fetched for an existing entry.
    private static func allocatedSize(_ url: URL) -> (bytes: Int64, complete: Bool) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, false) }
        if values.isRegularFile == false { return (0, true) }
        return (Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0), true)
    }

    /// Reused across the per-row UI path (cell `viewFor`, alerts, subtitles).
    /// `ByteCountFormatter` is NOT thread-safe; every `FileSize.string` caller
    /// runs on the main thread — keep it that way.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}
