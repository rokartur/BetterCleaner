import Foundation

/// How safe a developer directory is to remove blindly.
/// - `safeCache`: pure regenerable cache/derived data — fine to bulk-select.
/// - `askFirst`: holds real downloaded/built artifacts (installed gems, local
///   Maven/Gradle/Cargo repos) that are slow to rebuild and may include
///   locally-published packages — never auto-selected, ticked individually.
enum DevTier {
    case safeCache
    case askFirst
}

/// One development-tool cache directory, grouped by environment.
struct DevLocation {
    let category: String
    let path: String
    let tier: DevTier
}

/// Catalog of developer cache/derived directories worth reclaiming. All paths
/// are user-writable (no admin needed). Home-relative paths are expanded.
enum DevLocations {
    /// (category, home-relative subpath, tier)
    private static let entries: [(String, String, DevTier)] = [
        // Xcode
        ("Xcode", "Library/Developer/Xcode/DerivedData", .safeCache),
        ("Xcode", "Library/Developer/Xcode/Archives", .askFirst),
        ("Xcode", "Library/Developer/Xcode/iOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/watchOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/tvOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/CoreSimulator/Caches", .safeCache),
        ("Xcode", "Library/Caches/com.apple.dt.Xcode", .safeCache),
        // SwiftPM clone/build cache (re-fetched on demand).
        ("Swift", "Library/Caches/org.swift.swiftpm", .safeCache),
        // Node
        ("Node", ".npm/_cacache", .safeCache),
        ("Node", "Library/Caches/Yarn", .safeCache),
        ("Node", ".yarn/cache", .safeCache),
        ("Node", ".pnpm-store", .safeCache),
        ("Node", ".node-gyp", .safeCache),
        // Python
        ("Python", "Library/Caches/pip", .safeCache),
        ("Python", ".cache/pip", .safeCache),
        // Rust
        ("Rust", ".cargo/registry", .askFirst),
        ("Rust", ".cargo/git", .askFirst),
        // Go
        ("Go", "Library/Caches/go-build", .safeCache),
        ("Go", "go/pkg/mod/cache", .askFirst),
        // Ruby
        ("Ruby", ".gem", .askFirst),
        // Gradle / Maven
        ("Gradle", ".gradle/caches", .askFirst),
        ("Gradle", ".gradle/wrapper", .safeCache),
        ("Maven", ".m2/repository", .askFirst),
        // CocoaPods / Carthage
        ("CocoaPods", "Library/Caches/CocoaPods", .safeCache),
        ("Carthage", "Library/Caches/org.carthage.CarthageKit", .safeCache),
        // IDEs
        ("VS Code", "Library/Application Support/Code/Cache", .safeCache),
        ("VS Code", "Library/Application Support/Code/CachedData", .safeCache),
        ("JetBrains", "Library/Caches/JetBrains", .safeCache),
        // Containers / mobile / misc heavyweight caches.
        // Docker Desktop VM disk image — often the single largest dev artifact.
        ("Docker", "Library/Containers/com.docker.docker/Data/vms", .askFirst),
        // Android SDK emulator system images.
        ("Android", "Library/Android/sdk/system-images", .askFirst),
        // Dart / Flutter package cache.
        ("Flutter", ".pub-cache", .askFirst),
        // Bazel + ccache build caches.
        ("Bazel", ".cache/bazel", .safeCache),
        ("ccache", ".ccache", .safeCache),
        // Homebrew downloaded bottles / cache.
        ("Homebrew", "Library/Caches/Homebrew", .safeCache),
        // Conda package cache.
        ("Conda", "miniconda3/pkgs", .askFirst),
    ]

    static func all() -> [DevLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return entries.map { (category, sub, tier) in
            DevLocation(category: category, path: home.appendingPathComponent(sub).path, tier: tier)
        }
    }
}
