import Foundation

/// Matches manually-installed `/Applications` apps to known Homebrew casks so the
/// user can "adopt" them (let Homebrew manage updates for an app they dragged in by
/// hand). Matching is conservative — an app is only a candidate when its slugified
/// name is an exact known cask token — so adoption never targets the wrong cask.
enum HomebrewAdopter {
    struct Candidate {
        let appName: String
        let appPath: String
        let caskToken: String
    }

    /// Non-managed `/Applications/*.app` whose slug matches a known cask token.
    static func candidates() -> [Candidate] {
        guard HomebrewEnvironment.isInstalled else { return [] }
        let fm = FileManager.default
        let appsDir = "/Applications"
        guard let entries = try? fm.contentsOfDirectory(atPath: appsDir) else { return [] }

        let knownTokens = allCaskTokens()
        guard !knownTokens.isEmpty else { return [] }
        let managed = managedAppBundleNames()

        var result: [Candidate] = []
        for entry in entries where entry.hasSuffix(".app") {
            if managed.contains(entry.lowercased()) { continue }
            let appName = String(entry.dropLast(4))
            let token = slug(appName)
            guard !token.isEmpty, knownTokens.contains(token) else { continue }
            result.append(Candidate(appName: appName, appPath: "\(appsDir)/\(entry)", caskToken: token))
        }
        return result.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Every cask token Homebrew knows about (`brew casks` — local, fast).
    private static func allCaskTokens() -> Set<String> {
        guard let brew = HomebrewEnvironment.brewPath else { return [] }
        let out = CommandRunner.run(brew, ["casks"], environment: HomebrewEnvironment.environment())
        guard out.ok else { return [] }
        return Set(out.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// `<name>.app` bundle names already managed by an installed cask, so we never
    /// offer to adopt something Homebrew already owns.
    private static func managedAppBundleNames() -> Set<String> {
        Set(HomebrewService.installedPackages()
            .filter { $0.isCask }
            .map { "\($0.displayName).app".lowercased() })
    }

    /// Lowercase, non-alphanumerics collapsed to single hyphens — the common cask
    /// token shape (e.g. "Visual Studio Code" → "visual-studio-code").
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
