import Foundation
import CoreServices

/// Decides whether a file in a Library directory belongs to a given app, and
/// guards a denylist of critical files that must never be matched.
enum FileMatcher {
    /// Lowercased filenames (with extension stripped where relevant) that are
    /// never associated with an app — protects shared/system state from broad
    /// name matches.
    private static let protectedNames: Set<String> = [
        ".globalpreferences",
        "com.apple.globalpreferences",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systempreferences",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.spotlight",
        "com.apple.universalaccess",
        "com.apple.security",
        "com.apple.appstore",
        "com.apple.coreservices",
        "com.apple.safari",
        "com.apple.mail",
        "com.apple.messages",
        "com.apple.icloud",
        "com.apple.keychainaccess",
        "knowledge",
        "group containers",
        "containers",
    ]

    /// Lowercase + strip every non-alphanumeric character. Makes "Sublime Text"
    /// and "sublimetext" comparable and avoids spacing/punctuation noise.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// True for files/folders that must never be deleted regardless of match.
    static func isProtected(url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let stem = (name as NSString).deletingPathExtension
        return protectedNames.contains(name) || protectedNames.contains(stem)
    }

    /// How confidently a file is associated with an app.
    /// - `strong`: bundle-id match or full display/executable name — safe to
    ///   auto-select.
    /// - `weak`: only the app's *vendor* matched (its reverse-DNS namespace
    ///   `com.parallels.…`, or the vendor token "parallels" in a folder name like
    ///   "Parallels" / "Parallels Software"). Surfaced but never auto-selected,
    ///   because a shared-vendor folder (e.g. "Google", "Microsoft") may hold
    ///   other apps' data too.
    enum MatchStrength { case strong, weak }

    /// What evidence produced a match — lets the scanner disambiguate. A `bundleID`
    /// match is globally unique (an id belongs to exactly one app), so it never
    /// collides; `name` and `vendor` matches *can* be claimed by another installed
    /// app and must be checked before auto-selecting.
    enum MatchKind { case bundleID, name, vendor }

    /// A match: how confident, and what evidence produced it.
    struct Match {
        let strength: MatchStrength
        let kind: MatchKind
    }

    /// Whether `fileName` (a directory entry's last path component) is associated
    /// with `descriptor`, with the confidence and the evidence kind. Nil = no match.
    static func classify(fileName: String, descriptor: AppDescriptor, sensitivity: SearchSensitivity) -> Match? {
        let lower = fileName.lowercased()
        let ids = descriptor.allBundleIDs

        // Bundle identifiers — the strongest signal (primary + nested helpers).
        // com.foo.Bar.plist / com.foo.Bar.savedState / com.foo.Bar.<UUID>.plist
        for bid in ids where !bid.isEmpty {
            if lower == bid { return Match(strength: .strong, kind: .bundleID) }
            if lower.hasPrefix(bid + ".") || lower.hasPrefix(bid + " ") { return Match(strength: .strong, kind: .bundleID) }
            if sensitivity != .strict {
                // The id embedded as a whole, separator-delimited run — e.g. a
                // shared-file-list entry "com.apple.sharedfilelist.com.spotify.client.sfl2"
                // — is a confident (strong) match.
                if containsBoundedToken(lower, bid) { return Match(strength: .strong, kind: .bundleID) }
                // The id glued to a suffix with no separator ("com.foo.BarHelper")
                // is probably a helper, but indistinguishable from a sibling
                // ("com.foo.Bartender") — surface for manual review, never
                // auto-select. (A bare `contains` used to return .strong here and
                // also fired mid-token, auto-trashing unrelated files.) Real nested
                // helpers match exactly via extraBundleIDs above.
                if lower.hasPrefix(bid) { return Match(strength: .weak, kind: .bundleID) }
            }
        }

        // Never name-match Apple system files — they're only ever associated by an
        // exact bundle id above. Stops an app named "Safari"/"Mail"/"Core" from
        // sweeping in com.apple.* preferences/state.
        let isAppleApp = ids.contains { $0.hasPrefix("com.apple.") }
        if lower.hasPrefix("com.apple.") && !isAppleApp { return nil }

        // Display-name + executable terms, guarded against tiny names that would
        // over-match. Either term hitting is a strong signal. Even an exact
        // full-name equality needs a 3+ char term — otherwise a file literally
        // named "Go"/"R"/"X" would auto-match a 1-2 char app name.
        let terms = nameTerms(descriptor)
        let normFile = normalize(fileName)
        for term in terms where term.count >= 3 && normFile == term { return Match(strength: .strong, kind: .name) }

        switch sensitivity {
        case .strict:
            break
        case .standard:
            // Require a distinctive term and a match at a token boundary, not in
            // the middle of an identifier component (avoids "Core" hitting
            // "com.apple.SpeechRecognitionCore").
            for term in terms where term.count >= 4 {
                if matchesAtTokenBoundary(fileName: fileName, normName: term) { return Match(strength: .strong, kind: .name) }
            }
        case .aggressive:
            // Superset of .standard: a term that begins any filename token, or the
            // fully-normalized name, is a strong (auto-selectable) match. A bare
            // mid-string substring ("spotify" inside "multispotify") is too loose to
            // auto-select — it is surfaced as a weak (manual) match instead of the
            // old strong one that auto-trashed it.
            for term in terms where term.count >= 4 {
                if matchesAtTokenBoundary(fileName: fileName, normName: term) { return Match(strength: .strong, kind: .name) }
                if normFile.hasPrefix(term) { return Match(strength: .strong, kind: .name) }
                if normFile.contains(term) { return Match(strength: .weak, kind: .name) }
            }
        }

        // Vendor fallback (weak). Catches files in the app's reverse-DNS namespace
        // and vendor-named folders that the full app name misses — e.g. for
        // com.parallels.desktop.console: "com.parallels.Parallels Desktop.plist",
        // "Parallels", "Parallels Software".
        if sensitivity != .strict {
            for namespace in vendorNamespaces(descriptor) where lower.hasPrefix(namespace) {
                return Match(strength: .weak, kind: .vendor)
            }
            for token in vendorTokens(descriptor) {
                if matchesAtTokenBoundary(fileName: fileName, normName: token) { return Match(strength: .weak, kind: .vendor) }
            }
        }
        return nil
    }

    /// Confidence-only form. Nil = no match.
    static func match(fileName: String, descriptor: AppDescriptor, sensitivity: SearchSensitivity) -> MatchStrength? {
        classify(fileName: fileName, descriptor: descriptor, sensitivity: sensitivity)?.strength
    }

    /// Back-compat boolean form: any match, strong or weak.
    static func matches(fileName: String, descriptor: AppDescriptor, sensitivity: SearchSensitivity) -> Bool {
        classify(fileName: fileName, descriptor: descriptor, sensitivity: sensitivity) != nil
    }

    /// A precomputed view of *other* installed apps' strong identity signals, built
    /// once per scan so the per-file collision check is cheap. Collapses every other
    /// app's bundle ids and name terms into deduplicated sets, then answers "does
    /// any other app strongly claim this filename?" — the "no collisions" guard that
    /// keeps a name match from auto-selecting a file another app also owns.
    ///
    /// Only *strong* evidence vetoes (exact/anchored bundle id, exact/boundary/prefix
    /// name) — the same forms `classify` calls `.strong`. A weak signal (a bare
    /// substring, a glued bundle-id suffix, a shared vendor token) is deliberately
    /// NOT a veto: it would demote far too many legitimate auto-selects (e.g. any
    /// folder whose name merely contains a 4-char word another app uses).
    struct CollisionIndex {
        private let bundleIDs: [String]
        private let exactNameTerms: Set<String>   // normalized, count >= 3
        private let prefixNameTerms: [String]      // normalized, count >= 4

        init(_ others: [AppDescriptor]) {
            var ids = Set<String>()
            var exact = Set<String>()
            var prefix = Set<String>()
            for other in others {
                for bid in other.allBundleIDs where !bid.isEmpty { ids.insert(bid) }
                for term in nameTerms(other) {
                    if term.count >= 3 { exact.insert(term) }
                    if term.count >= 4 { prefix.insert(term) }
                }
            }
            bundleIDs = Array(ids)
            exactNameTerms = exact
            prefixNameTerms = Array(prefix)
        }

        /// True when some other app strongly claims `fileName`. Mirrors `classify`'s
        /// strong-match predicates exactly, so the precompute changes only speed,
        /// never which matches are considered colliding.
        func claims(fileName: String, sensitivity: SearchSensitivity) -> Bool {
            let lower = fileName.lowercased()
            // Strong bundle-id evidence (an id belongs to exactly one app).
            for bid in bundleIDs {
                if lower == bid { return true }
                if lower.hasPrefix(bid + ".") || lower.hasPrefix(bid + " ") { return true }
                if sensitivity != .strict, containsBoundedToken(lower, bid) { return true }
            }
            // Strong name evidence.
            let normFile = normalize(fileName)
            if exactNameTerms.contains(normFile) { return true }
            if sensitivity != .strict {
                for term in prefixNameTerms {
                    if matchesAtTokenBoundary(fileName: fileName, normName: term) { return true }
                    if sensitivity == .aggressive, normFile.hasPrefix(term) { return true }
                }
            }
            return false
        }
    }

    /// Whether any of `others` strongly claims `fileName` (the "no collisions"
    /// guard). Thin wrapper over `CollisionIndex` — kept for call sites/tests that
    /// pass a one-off app list; the scanner builds the index once and calls
    /// `claims` directly on the hot path.
    static func nameClaimedByOther(fileName: String, others: [AppDescriptor], sensitivity: SearchSensitivity) -> Bool {
        CollisionIndex(others).claims(fileName: fileName, sensitivity: sensitivity)
    }

    /// The normalized name signals for an app: display name, `CFBundleName` /
    /// bundle filename (`extraNames`), and the executable name. Cache and support
    /// folders are named after any of these, not just the display name.
    private static func nameTerms(_ descriptor: AppDescriptor) -> [String] {
        var terms: [String] = []
        func add(_ s: String) {
            let n = normalize(s)
            if !n.isEmpty, !terms.contains(n) { terms.append(n) }
        }
        add(descriptor.name)
        for extra in descriptor.extraNames { add(extra) }
        if let exe = descriptor.executable { add(exe) }
        return terms
    }

    /// Generic reverse-DNS components that never identify a vendor on their own.
    private static let genericVendorTokens: Set<String> = [
        "apple", "com", "org", "net", "io", "dev", "app", "apps", "www", "co",
        "group", "containers", "macos", "osx",
    ]

    /// The distinctive vendor token of each bundle id — the second reverse-DNS
    /// component (`com.PARALLELS.desktop`). Min length 4, non-generic. Internal so
    /// the scanner can decide whether a vendor is exclusive to one installed app.
    static func vendorTokens(_ descriptor: AppDescriptor) -> [String] {
        var tokens: [String] = []
        for bid in descriptor.allBundleIDs {
            let parts = bid.split(separator: ".").map(String.init)
            guard parts.count >= 2 else { continue }
            let vendor = parts[1]
            if vendor.count >= 4, !genericVendorTokens.contains(vendor), !tokens.contains(vendor) {
                tokens.append(vendor)
            }
        }
        return tokens
    }

    /// The vendor reverse-DNS namespace prefix of each bundle id
    /// (`com.parallels.`), so any file inside that namespace is attributed.
    /// Internal so the Spotlight scanner can apply the same tight filter.
    static func vendorNamespaces(_ descriptor: AppDescriptor) -> [String] {
        var namespaces: [String] = []
        for bid in descriptor.allBundleIDs {
            let parts = bid.split(separator: ".").map(String.init)
            guard parts.count >= 2 else { continue }
            let vendor = parts[1]
            guard vendor.count >= 4, !genericVendorTokens.contains(vendor) else { continue }
            let namespace = "\(parts[0]).\(vendor)."
            if !namespaces.contains(namespace) { namespaces.append(namespace) }
        }
        return namespaces
    }

    /// True if any alphanumeric token of `fileName` begins with `normName` —
    /// e.g. "Spotify" matches "com.spotify.client" (token "spotify") but not
    /// "multispotlight".
    private static func matchesAtTokenBoundary(fileName: String, normName: String) -> Bool {
        let tokens = fileName.lowercased().split { !CharacterSet.alphanumerics.contains($0.unicodeScalars.first ?? " ") }
        return tokens.contains { $0.hasPrefix(normName) }
    }

    /// True if `needle` occurs in `haystack` as a whole, separator-delimited run —
    /// bounded by a non-alphanumeric character (or the string edge) on both sides.
    /// Lets a bundle id match when it sits between dots inside a longer name
    /// ("com.apple.sharedfilelist.com.spotify.client.sfl2") while rejecting a
    /// mid-token coincidence ("mycom.spotify.clientx"). Both arguments are expected
    /// lowercased. Replaces a bare `contains`, which over-matched on substrings.
    private static func containsBoundedToken(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var from = haystack.startIndex
        while let range = haystack.range(of: needle, options: [], range: from..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !isAlnum(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex
                || !isAlnum(haystack[range.upperBound])
            if beforeOK && afterOK { return true }
            from = haystack.index(after: range.lowerBound)
        }
        return false
    }

    /// The sandbox container identifier (`MCMMetadataIdentifier`) for a
    /// `Containers` / `Group Containers` entry whose folder name is a UUID rather
    /// than a bundle id. Returns `nil` for plain (non-container) directories.
    static func containerIdentifier(of url: URL) -> String? {
        let candidates = [
            ".com.apple.containermanager.metadata.plist",
            "Container.plist",
        ]
        for name in candidates {
            let plist = url.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: plist),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = obj as? [String: Any] else { continue }
            if let id = dict["MCMMetadataIdentifier"] as? String, !id.isEmpty { return id }
            if let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Whether a resolved container identifier belongs to `descriptor`
    /// (exact, or a parent/child of one of its bundle ids).
    static func containerMatches(identifier: String, descriptor: AppDescriptor) -> Bool {
        let id = identifier.lowercased()
        guard !id.isEmpty else { return false }
        for bid in descriptor.allBundleIDs where !bid.isEmpty {
            if id == bid || id.hasPrefix(bid + ".") || bid.hasPrefix(id + ".") { return true }
        }
        return false
    }

    /// True when a folder name carries no lexical signal — a UUID, or a long
    /// undelimited hex hash — so it can only be attributed by metadata, not by name
    /// (e.g. a Spotlight/WebKit cache folder named after a content hash). Used to
    /// gate the (relatively costly) Spotlight-metadata lookup to just these entries.
    static func looksOpaque(_ name: String) -> Bool {
        if isUUID(name) { return true }
        let stem = (name as NSString).deletingPathExtension
        guard stem.count >= 16 else { return false }
        return stem.unicodeScalars.allSatisfy { s in
            (s >= "0" && s <= "9") || (s >= "a" && s <= "f") || (s >= "A" && s <= "F")
        }
    }

    /// 8-4-4-4-12 hex UUID (the sandbox container / simulator naming scheme).
    private static func isUUID(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5 else { return false }
        for (part, len) in zip(parts, lengths) {
            guard part.count == len,
                  part.unicodeScalars.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F") })
            else { return false }
        }
        return true
    }

    /// The Spotlight-indexed bundle identifier (`kMDItemCFBundleIdentifier`) recorded
    /// for the item at `url`, lowercased — or nil if Spotlight has none. An exact id
    /// match is an anchored (no-false-positive) ownership signal for opaque-named
    /// leftovers the lexical matcher can't attribute. Index lookup, no process spawn,
    /// but still gate calls behind `looksOpaque`. Returns nil for unindexed paths
    /// (much of `~/Library` is excluded from Spotlight) — harmless, just no signal.
    static func metadataBundleID(of url: URL) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String,
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}
