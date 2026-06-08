import Foundation

/// Applies a set of `UserCondition`s to one file during a leftover scan.
///
/// Built once per scan for a specific app: it keeps only the enabled rules whose
/// `appScope` matches the app (or is global), precompiling each regex a single
/// time. `decide` is then a pure, allocation-free lookup per file.
///
/// Precedence: **exclude beats include**. If any exclude rule matches, the file is
/// dropped regardless of include rules.
struct ConditionEvaluator {
    enum Decision: Equatable { case forceInclude, forceExclude, none }

    private struct Compiled {
        let condition: UserCondition
        let regex: NSRegularExpression?
        /// `condition.value` lowercased once at compile time — the value is fixed
        /// for the whole scan, so re-lowercasing it per file was constant waste.
        let lowerValue: String
    }

    private let compiled: [Compiled]
    private let appBundleID: String

    /// - Parameters:
    ///   - conditions: the user's full rule list (enabled + disabled).
    ///   - descriptor: the app being scanned, used for scope + bundle-id target.
    init(conditions: [UserCondition], descriptor: AppDescriptor) {
        appBundleID = descriptor.bundleID?.lowercased() ?? ""
        let ids = Set(descriptor.allBundleIDs)
        compiled = conditions.compactMap { c in
            guard c.enabled, !c.value.isEmpty else { return nil }
            if let scope = c.appScope, !scope.isEmpty, !ids.contains(scope) { return nil }
            if c.op == .regex {
                // Invalid / oversized patterns drop the rule rather than match-all.
                guard let regex = SafeRegex.compile(c.value) else { return nil }
                return Compiled(condition: c, regex: regex, lowerValue: "")
            }
            return Compiled(condition: c, regex: nil, lowerValue: c.value.lowercased())
        }
    }

    var isEmpty: Bool { compiled.isEmpty }

    /// Decide a file by its name and full path. Exclude wins over include.
    func decide(fileName: String, path: String) -> Decision {
        guard !compiled.isEmpty else { return .none }
        var include = false
        for item in compiled {
            let subject: String
            switch item.condition.target {
            case .name: subject = fileName
            case .path: subject = path
            case .bundleID: subject = appBundleID
            }
            guard matches(item, subject: subject) else { continue }
            if item.condition.kind == .exclude { return .forceExclude }
            include = true
        }
        return include ? .forceInclude : .none
    }

    private func matches(_ item: Compiled, subject: String) -> Bool {
        if item.condition.op == .regex {
            guard let regex = item.regex else { return false }
            return SafeRegex.matches(regex, subject)
        }
        let s = subject.lowercased()
        let v = item.lowerValue
        switch item.condition.op {
        case .contains: return s.contains(v)
        case .equals: return s == v
        case .prefix: return s.hasPrefix(v)
        case .suffix: return s.hasSuffix(v)
        case .regex: return false // handled above
        }
    }
}
