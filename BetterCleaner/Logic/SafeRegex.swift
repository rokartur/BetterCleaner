import Foundation

/// Bounded, fail-soft regex compilation for user-supplied condition patterns.
///
/// An invalid pattern compiles to `nil` so the owning rule simply no-ops rather
/// than throwing mid-scan. Patterns are length-capped and matching subjects are
/// short (file names / paths), which keeps ICU's backtracking bounded. ICU has no
/// hard match timeout — the length cap is the mitigation (documented residual
/// risk for pathological patterns).
enum SafeRegex {
    static let maxPatternLength = 200

    /// Compile a case-insensitive regex, or `nil` if empty, too long, or invalid.
    static func compile(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty, pattern.count <= maxPatternLength else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Whether `pattern` is a usable regex (for live UI validation).
    static func isValid(_ pattern: String) -> Bool {
        compile(pattern) != nil
    }

    /// Whether `regex` matches anywhere in `subject`.
    static func matches(_ regex: NSRegularExpression, _ subject: String) -> Bool {
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return regex.firstMatch(in: subject, options: [], range: range) != nil
    }
}
