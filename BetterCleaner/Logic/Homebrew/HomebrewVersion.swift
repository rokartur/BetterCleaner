import Foundation

enum HomebrewVersion {
    /// Homebrew versions are not strict SemVer (`1.2,345`, `1.2_1`, `latest`). Numeric
    /// NSString comparison handles their common forms without inventing a package parser.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = comparablePart(lhs)
        let right = comparablePart(rhs)
        return left.compare(right, options: [.numeric, .caseInsensitive])
    }

    static func isAtLeast(_ installed: String, _ available: String) -> Bool {
        guard !available.isEmpty else { return false }
        if available.caseInsensitiveCompare("latest") == .orderedSame { return true }
        guard !installed.isEmpty else { return false }
        return compare(installed, available) != .orderedAscending
    }

    static func buildPart(_ version: String) -> String? {
        let parts = version.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let build = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return build.isEmpty ? nil : build
    }

    private static func comparablePart(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .split(separator: ",", maxSplits: 1)
            .first
            .map(String.init) ?? version
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
