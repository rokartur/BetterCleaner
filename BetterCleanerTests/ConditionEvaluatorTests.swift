import Testing
import Foundation
@testable import BetterCleaner

@Suite struct ConditionEvaluatorTests {
    private let bar = AppDescriptor(bundleID: "com.foo.Bar", name: "Bar")

    private func evaluator(_ conditions: [UserCondition], for descriptor: AppDescriptor? = nil) -> ConditionEvaluator {
        ConditionEvaluator(conditions: conditions, descriptor: descriptor ?? bar)
    }

    @Test func includeRuleForcesInclude() {
        let rules = [UserCondition(kind: .include, target: .name, op: .contains, value: "cache")]
        #expect(evaluator(rules).decide(fileName: "MyCache.db", path: "/x/MyCache.db") == .forceInclude)
    }

    @Test func excludeRuleForcesExclude() {
        let rules = [UserCondition(kind: .exclude, target: .name, op: .suffix, value: ".log")]
        #expect(evaluator(rules).decide(fileName: "session.log", path: "/x/session.log") == .forceExclude)
    }

    @Test func excludeBeatsInclude() {
        let rules = [
            UserCondition(kind: .include, target: .name, op: .contains, value: "data"),
            UserCondition(kind: .exclude, target: .name, op: .contains, value: "data"),
        ]
        #expect(evaluator(rules).decide(fileName: "userdata", path: "/x/userdata") == .forceExclude)
    }

    @Test func noMatchIsNone() {
        let rules = [UserCondition(kind: .include, target: .name, op: .equals, value: "exact")]
        #expect(evaluator(rules).decide(fileName: "other", path: "/x/other") == .none)
    }

    @Test func disabledRuleIsIgnored() {
        let rules = [UserCondition(enabled: false, kind: .exclude, target: .name, op: .contains, value: "log")]
        #expect(evaluator(rules).isEmpty)
        #expect(evaluator(rules).decide(fileName: "a.log", path: "/x/a.log") == .none)
    }

    @Test func emptyValueRuleIsDropped() {
        let rules = [UserCondition(kind: .exclude, target: .name, op: .contains, value: "")]
        #expect(evaluator(rules).isEmpty)
    }

    @Test func appScopeNilAppliesEverywhere() {
        let rules = [UserCondition(kind: .exclude, target: .name, op: .contains, value: "log", appScope: nil)]
        #expect(evaluator(rules).decide(fileName: "a.log", path: "/a.log") == .forceExclude)
    }

    @Test func appScopeMatchingAppApplies() {
        let rules = [UserCondition(kind: .exclude, target: .name, op: .contains, value: "log", appScope: "com.foo.bar")]
        #expect(evaluator(rules).decide(fileName: "a.log", path: "/a.log") == .forceExclude)
    }

    @Test func appScopeOtherAppIsDropped() {
        let rules = [UserCondition(kind: .exclude, target: .name, op: .contains, value: "log", appScope: "com.other.app")]
        // Rule pinned to a different app → not applicable to `bar`.
        #expect(evaluator(rules).isEmpty)
    }

    @Test func opsAreCaseInsensitive() {
        #expect(evaluator([UserCondition(kind: .include, target: .name, op: .contains, value: "CACHE")])
            .decide(fileName: "mycache", path: "/x") == .forceInclude)
        #expect(evaluator([UserCondition(kind: .include, target: .name, op: .equals, value: "FOO")])
            .decide(fileName: "foo", path: "/x") == .forceInclude)
        #expect(evaluator([UserCondition(kind: .include, target: .name, op: .prefix, value: "Com.Foo")])
            .decide(fileName: "com.foo.bar.plist", path: "/x") == .forceInclude)
        #expect(evaluator([UserCondition(kind: .include, target: .name, op: .suffix, value: ".PLIST")])
            .decide(fileName: "a.plist", path: "/x") == .forceInclude)
    }

    @Test func pathTargetMatchesFullPath() {
        let rules = [UserCondition(kind: .exclude, target: .path, op: .contains, value: "/node_modules/")]
        #expect(evaluator(rules).decide(fileName: "index.js", path: "/proj/node_modules/index.js") == .forceExclude)
        #expect(evaluator(rules).decide(fileName: "index.js", path: "/proj/src/index.js") == .none)
    }

    @Test func bundleIDTargetMatchesScannedApp() {
        let rules = [UserCondition(kind: .exclude, target: .bundleID, op: .contains, value: "com.foo")]
        #expect(evaluator(rules).decide(fileName: "anything", path: "/x") == .forceExclude)
    }

    @Test func validRegexMatches() {
        let rules = [UserCondition(kind: .include, target: .name, op: .regex, value: "^cache.*\\.db$")]
        #expect(evaluator(rules).decide(fileName: "Cache_main.db", path: "/x") == .forceInclude)
        #expect(evaluator(rules).decide(fileName: "main.db.bak", path: "/x") == .none)
    }

    @Test func invalidRegexRuleIsDropped() {
        // Unbalanced bracket → does not compile → rule no-ops (never match-all).
        let rules = [UserCondition(kind: .exclude, target: .name, op: .regex, value: "[unclosed")]
        #expect(evaluator(rules).isEmpty)
        #expect(evaluator(rules).decide(fileName: "anything", path: "/x") == .none)
    }

    @Test func protectedNameRemainsProtected() {
        // The scanner guards protected files BEFORE conditions run; this locks in
        // that an include rule can never resurrect one.
        #expect(FileMatcher.isProtected(url: URL(fileURLWithPath: "/x/com.apple.finder.plist")))
        #expect(FileMatcher.isProtected(url: URL(fileURLWithPath: "/x/.GlobalPreferences.plist")))
    }
}
