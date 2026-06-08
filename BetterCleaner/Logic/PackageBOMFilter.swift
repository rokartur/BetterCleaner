import Foundation

enum PackageBOMFilter {
    /// Bundle wrappers whose internals collapse to the bundle root (deleting the
    /// root removes the whole thing; listing every nested file is noise and risky).
    static let bundleExtensions: Set<String> = [
        "app", "kext", "framework", "plugin", "bundle", "component", "vst", "vst3",
        "au", "clap", "xpc", "appex", "qlgenerator", "prefpane", "dsym", "pkg",
        "mdimporter", "driver", "saver", "wdgt", "menu", "spreporter",
    ]

    /// Bare directories that must never be offered as a deletion target — removing
    /// any of these would damage the system or other apps.
    static let systemDirs: Set<String> = [
        "/", "/Applications", "/Applications/Utilities",
        "/Library", "/Library/Application Support", "/Library/Audio",
        "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/Components",
        "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3", "/Library/Caches", "/Library/ColorPickers",
        "/Library/Components", "/Library/Extensions", "/Library/Filesystems",
        "/Library/Fonts", "/Library/Frameworks", "/Library/Input Methods",
        "/Library/Internet Plug-Ins", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PreferencePanes", "/Library/Preferences", "/Library/PrivilegedHelperTools",
        "/Library/QuickLook", "/Library/Screen Savers", "/Library/Services",
        "/Library/Spotlight", "/Library/StartupItems", "/Library/Widgets",
        "/System", "/System/Library", "/Users", "/Users/Shared",
        "/bin", "/opt", "/opt/homebrew", "/opt/local",
        "/private", "/private/etc", "/private/tmp", "/private/var",
        "/sbin", "/tmp", "/usr", "/usr/bin", "/usr/lib", "/usr/libexec",
        "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/sbin",
        "/usr/sbin", "/usr/share", "/var",
    ]

    /// Full pipeline: drop resource-fork files, collapse bundle internals, drop
    /// bare system directories, then remove paths nested under a kept ancestor.
    static func filter(_ absolutePaths: [String]) -> [String] {
        let noForks = absolutePaths.filter { !($0 as NSString).lastPathComponent.hasPrefix("._") }
        let collapsed = noForks.map(collapseBundle)
        let noSystem = collapsed.filter { !systemDirs.contains($0) }
        return removeRedundantChildPaths(noSystem)
    }

    /// Truncate a path at the first component that is a recognized bundle wrapper,
    /// so `/Applications/Foo.app/Contents/MacOS/Foo` becomes `/Applications/Foo.app`.
    static func collapseBundle(_ path: String) -> String {
        let comps = (path as NSString).pathComponents
        var acc = ""
        for comp in comps {
            acc = (acc as NSString).appendingPathComponent(comp)
            let ext = (comp as NSString).pathExtension.lowercased()
            if !ext.isEmpty, bundleExtensions.contains(ext) { return acc }
        }
        return path
    }

    /// Drop any path that is a descendant of another kept path. Input is sorted so
    /// every ancestor is seen before its children; a path is redundant when any of
    /// its ancestor prefixes was already kept.
    static func removeRedundantChildPaths(_ paths: [String]) -> [String] {
        let sorted = Array(Set(paths)).sorted()
        var kept = Set<String>()
        var result: [String] = []
        for path in sorted {
            let comps = (path as NSString).pathComponents
            var prefix = ""
            var isChild = false
            for comp in comps.dropLast() {
                prefix = (prefix as NSString).appendingPathComponent(comp)
                if kept.contains(prefix) { isChild = true; break }
            }
            if isChild { continue }
            kept.insert(path)
            result.append(path)
        }
        return result
    }
}
