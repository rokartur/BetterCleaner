import Foundation

/// A user-defined matching rule for the per-app leftover scan. Include rules
/// surface a file the built-in matcher would miss; exclude rules drop a file the
/// matcher would otherwise take. Rules can be global (`appScope == nil`) or pinned
/// to a single app by its bundle id.
///
/// Safety: an include rule can never override `FileMatcher.isProtected`, never
/// auto-select, and never inject a system-domain file — see `LeftoverScanner`.
struct UserCondition: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case include, exclude
        var title: String { self == .include ? "Include" : "Exclude" }
    }

    enum Target: String, Codable, CaseIterable {
        case name, path, bundleID
        var title: String {
            switch self {
            case .name: return "File name"
            case .path: return "Full path"
            case .bundleID: return "App bundle ID"
            }
        }
    }

    enum Op: String, Codable, CaseIterable {
        case contains, equals, prefix, suffix, regex
        var title: String {
            switch self {
            case .contains: return "contains"
            case .equals: return "equals"
            case .prefix: return "starts with"
            case .suffix: return "ends with"
            case .regex: return "matches regex"
            }
        }
    }

    var id: UUID
    var enabled: Bool
    var kind: Kind
    var target: Target
    var op: Op
    var value: String
    /// Lowercased bundle id the rule is pinned to; `nil` applies to every app.
    var appScope: String?

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        kind: Kind = .exclude,
        target: Target = .name,
        op: Op = .contains,
        value: String = "",
        appScope: String? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.target = target
        self.op = op
        self.value = value
        self.appScope = appScope
    }

    /// A human-readable one-liner for the rules table.
    var sentence: String {
        let scope = (appScope?.isEmpty == false) ? appScope! : "all apps"
        return "\(kind.title) when \(target.title.lowercased()) \(op.title) “\(value)” · \(scope)"
    }
}
