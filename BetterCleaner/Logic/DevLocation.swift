import Foundation

/// How safe a developer directory is to remove blindly.
/// - `safeCache`: pure regenerable cache/derived data — fine to bulk-select.
/// - `askFirst`: holds real downloaded/built artifacts (installed gems, local
///   Maven/Gradle/Cargo repos, language runtimes, IDE extensions, SDKs) that are
///   slow to rebuild and may include locally-published packages — never
///   auto-selected, ticked individually.
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

/// Catalog of developer cache/derived directories worth reclaiming. Aims for
/// parity with Pearcleaner's environment list plus a wide set of extras so
/// practically every common toolchain is covered. All paths are user-writable
/// (no admin needed). Home-relative paths are expanded; entries starting with
/// `/` are absolute; entries containing `*` are glob patterns expanded at scan
/// time (see `DevGlob`).
///
/// Tiering rule: pure regenerable caches are `.safeCache` (auto-selectable);
/// installed toolchains/SDKs/runtimes/extensions and local package stores are
/// `.askFirst` (manual tick only — re-fetching or rebuilding them is costly,
/// and some may hold locally-published artifacts).
enum DevLocations {
    /// (category, subpath, tier). Subpath is home-relative unless it starts
    /// with `/`; a `*` marks a glob expanded against the filesystem at scan time.
    private static let entries: [(String, String, DevTier)] = [
        // ── Apple / Xcode ────────────────────────────────────────────
        ("Xcode", "Library/Developer/Xcode/DerivedData", .safeCache),
        ("Xcode", "Library/Developer/Xcode/Archives", .askFirst),
        ("Xcode", "Library/Developer/Xcode/iOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/watchOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/tvOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/macOS DeviceSupport", .safeCache),
        ("Xcode", "Library/Developer/Xcode/DocumentationCache", .safeCache),
        ("Xcode", "Library/Developer/CoreSimulator/Caches", .safeCache),
        ("Xcode", "Library/Developer/DeveloperDiskImages", .safeCache),
        ("Xcode", "Library/Caches/com.apple.dt.Xcode", .safeCache),
        ("Xcode", "Library/Caches/com.apple.dt.xcodebuild", .safeCache),
        ("Xcode", "Library/Caches/com.apple.dt.Xcode.sourcecontrol.Git", .safeCache),
        // SwiftPM clone/build cache (re-fetched on demand).
        ("Swift", "Library/Caches/org.swift.swiftpm", .safeCache),
        ("Swift", ".swiftpm/cache", .safeCache),

        // ── JavaScript / Node ────────────────────────────────────────
        ("Node", ".npm/_cacache", .safeCache),
        ("Node", "Library/Caches/Yarn", .safeCache),
        ("Node", ".yarn/cache", .safeCache),
        ("Node", ".cache/yarn", .safeCache),
        ("Node", ".yarn-cache", .safeCache),
        ("Node", ".pnpm-store", .safeCache),
        ("Node", "Library/pnpm/store", .safeCache),
        ("Node", ".node-gyp", .safeCache),
        ("Node", ".bun/install/cache", .safeCache),
        ("Node", "Library/Caches/deno", .safeCache),
        ("Node", ".cache/deno", .safeCache),
        // nvm-installed Node runtimes (real installs, not cache).
        ("Node", ".nvm/versions/node/*", .askFirst),
        // Headless-browser binaries downloaded by test tooling (re-fetchable).
        ("Node", ".cache/puppeteer", .safeCache),
        ("Node", "Library/Caches/ms-playwright", .safeCache),
        ("Node", "Library/Caches/Cypress", .safeCache),
        ("Node", "Library/Caches/electron", .safeCache),

        // ── Python ───────────────────────────────────────────────────
        ("Python", "Library/Caches/pip", .safeCache),
        ("Python", ".cache/pip", .safeCache),
        ("Python", "Library/Caches/pypoetry", .safeCache),
        ("Python", ".cache/pypoetry", .safeCache),
        ("Python", ".cache/uv", .safeCache),
        ("Python", ".local/share/uv", .askFirst),
        ("Python", ".pyenv/cache", .safeCache),

        // ── Ruby ─────────────────────────────────────────────────────
        ("Ruby", ".gem", .askFirst),
        ("Ruby", ".bundle/cache", .safeCache),

        // ── Rust ─────────────────────────────────────────────────────
        ("Rust", ".cargo/registry", .askFirst),
        ("Rust", ".cargo/git", .askFirst),
        ("Rust", ".cache/sccache", .safeCache),
        ("Rust", "Library/Caches/Mozilla.sccache", .safeCache),

        // ── Go ───────────────────────────────────────────────────────
        ("Go", "Library/Caches/go-build", .safeCache),
        ("Go", "go/pkg/mod/cache", .askFirst),
        ("Go", "go/bin", .askFirst),

        // ── JVM (Gradle / Maven / sbt / Coursier) ────────────────────
        ("Gradle", ".gradle/caches", .askFirst),
        ("Gradle", ".gradle/wrapper", .safeCache),
        ("Maven", ".m2/repository", .askFirst),
        ("sbt", ".ivy2/cache", .safeCache),
        ("sbt", ".sbt/boot", .safeCache),
        ("Coursier", "Library/Caches/Coursier", .safeCache),
        ("Coursier", ".cache/coursier", .safeCache),

        // ── Apple package managers ───────────────────────────────────
        ("CocoaPods", "Library/Caches/CocoaPods", .safeCache),
        ("CocoaPods", ".cocoapods/repos", .askFirst),
        ("Carthage", "Library/Caches/org.carthage.CarthageKit", .safeCache),

        // ── PHP / .NET / functional / niche languages ────────────────
        ("Composer", ".composer/cache", .safeCache),
        ("Composer", "Library/Caches/composer", .safeCache),
        (".NET", ".nuget/packages", .askFirst),
        (".NET", "Library/Caches/NuGet", .safeCache),
        (".NET", ".dotnet", .askFirst),
        ("Elixir", ".hex/packages", .safeCache),
        ("Elixir", ".cache/rebar3", .safeCache),
        ("Haskell", ".stack", .askFirst),
        ("Haskell", ".cabal/packages", .askFirst),
        ("Julia", ".julia/compiled", .safeCache),
        ("Julia", ".julia/artifacts", .askFirst),
        ("OCaml", ".opam/download-cache", .safeCache),
        ("Crystal", ".cache/shards", .safeCache),
        ("Zig", ".cache/zig", .safeCache),
        ("Nix", ".cache/nix", .safeCache),
        ("Clang", ".cache/clangd", .safeCache),

        // ── Dart / Flutter ───────────────────────────────────────────
        ("Flutter", ".pub-cache", .askFirst),
        ("Flutter", "Library/Caches/flutter_engine", .safeCache),

        // ── Containers / cloud / infra ───────────────────────────────
        // Docker Desktop VM disk image — often the single largest dev artifact.
        ("Docker", "Library/Containers/com.docker.docker/Data/vms", .askFirst),
        ("Podman", ".local/share/containers", .askFirst),
        ("Vagrant", ".vagrant.d/boxes", .askFirst),
        ("Kubernetes", ".minikube/cache", .safeCache),
        ("Kubernetes", ".kube/cache", .safeCache),
        ("Terraform", ".terraform.d/plugin-cache", .safeCache),
        ("Helm", "Library/Caches/helm", .safeCache),

        // ── Mobile / game engines ────────────────────────────────────
        // Android SDK emulator system images.
        ("Android", "Library/Android/sdk/system-images", .askFirst),
        ("Android", ".android", .askFirst),
        ("Android", "Library/Logs/AndroidStudio", .safeCache),
        ("Android", "Library/Caches/Google/AndroidStudio*", .safeCache),
        ("Unity", "Library/Caches/com.unity3d.UnityEditor", .safeCache),
        ("Unity", "Library/Unity/cache", .safeCache),
        ("Unreal", "Library/Caches/UnrealEngine", .safeCache),

        // ── Build accelerators ───────────────────────────────────────
        ("Bazel", ".cache/bazel", .safeCache),
        ("ccache", ".ccache", .safeCache),

        // ── System package managers ──────────────────────────────────
        // Homebrew downloaded bottles / cache.
        ("Homebrew", "Library/Caches/Homebrew", .safeCache),
        // Conda package caches (the env trees themselves are real installs).
        ("Conda", "miniconda3/pkgs", .askFirst),
        ("Conda", "anaconda3/pkgs", .askFirst),
        ("Conda", ".conda/pkgs", .askFirst),

        // ── IDEs ─────────────────────────────────────────────────────
        ("JetBrains", "Library/Caches/JetBrains", .safeCache),
        ("JetBrains", "Library/Logs/JetBrains", .safeCache),
        ("Zed", "Library/Caches/Zed", .safeCache),
        ("Zed", "Library/Application Support/Zed/node/cache", .safeCache),
        ("VS Code", ".vscode/extensions", .askFirst),
        ("Cursor", ".cursor/extensions", .askFirst),
    ]

    /// Electron-based editors share an identical regenerable cache-dir layout
    /// under `~/Library/Application Support/<app>/`. (display category, folder)
    private static let electronEditors: [(String, String)] = [
        ("VS Code", "Code"),
        ("VS Code Insiders", "Code - Insiders"),
        ("VSCodium", "VSCodium"),
        ("Cursor", "Cursor"),
        ("Windsurf", "Windsurf"),
    ]

    /// Pure-cache subdirectories every Electron/Chromium editor regenerates.
    private static let electronCacheSubdirs: [String] = [
        "Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs",
        "Code Cache", "CachedConfigurations", "CachedProfilesData",
        "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage",
    ]

    static func all() -> [DevLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func makePath(_ sub: String) -> String {
            sub.hasPrefix("/") ? sub : home.appendingPathComponent(sub).path
        }

        var locations = entries.map { (category, sub, tier) in
            DevLocation(category: category, path: makePath(sub), tier: tier)
        }

        // Generate the safe cache subdirs for each Electron editor rather than
        // hand-listing ~50 near-identical lines.
        for (category, folder) in electronEditors {
            for sub in electronCacheSubdirs {
                let p = makePath("Library/Application Support/\(folder)/\(sub)")
                locations.append(DevLocation(category: category, path: p, tier: .safeCache))
            }
        }

        return locations
    }
}
