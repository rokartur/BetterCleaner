import Foundation
import Darwin

/// Expands a shell-style glob pattern (one containing `*`) into the set of
/// existing filesystem paths that match. Used by the developer-cache scan for
/// catalog entries like `~/.nvm/versions/node/*` or `…/AndroidStudio*`, where
/// the concrete directory names are version- or install-specific and can't be
/// hard-coded.
enum DevGlob {
    /// Returns absolute paths matching `pattern`, or `[]` if nothing matches
    /// (or the pattern is malformed). Non-glob patterns match only if the exact
    /// path exists.
    static func expand(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        // GLOB_MARK appends a trailing "/" to matched directories; GLOB_NOSORT
        // skips the alphabetical sort we don't need (results get sized + sorted
        // by the scanner anyway).
        guard glob(pattern, GLOB_MARK | GLOB_NOSORT, nil, &g) == 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(g.gl_pathc))
        for i in 0..<Int(g.gl_pathc) {
            guard let c = g.gl_pathv[i] else { continue }
            out.append(String(cString: c))
        }
        return out
    }
}
