import Testing
import Foundation
@testable import BetterCleaner

@Suite struct DevLocationTests {
    @Test func allReturnsAbsoluteHomeExpandedPaths() {
        let locations = DevLocations.all()
        #expect(!locations.isEmpty)
        #expect(locations.allSatisfy { $0.path.hasPrefix("/") })
        #expect(locations.allSatisfy { !$0.category.isEmpty })
    }

    @Test func coversKeyEnvironments() {
        let categories = Set(DevLocations.all().map { $0.category })
        // Core languages / build tools.
        #expect(categories.contains("Xcode"))
        #expect(categories.contains("Node"))
        #expect(categories.contains("Python"))
        #expect(categories.contains("Rust"))
        #expect(categories.contains("Go"))
        // Heavyweight reclaims added from cleaner research (Docker VM, Homebrew cache).
        #expect(categories.contains("Docker"))
        #expect(categories.contains("Homebrew"))
        // Pearcleaner-parity + extras: editors, JVM, .NET, infra, niche langs.
        #expect(categories.contains("VS Code"))
        #expect(categories.contains("Cursor"))
        #expect(categories.contains("JetBrains"))
        #expect(categories.contains("Composer"))
        #expect(categories.contains(".NET"))
        #expect(categories.contains("Kubernetes"))
        #expect(categories.contains("Julia"))
    }

    @Test func askFirstArtifactsAreNotAutoSelectable() {
        // Real artifacts (Docker VM, Maven/Gradle repos, conda pkgs, installed
        // runtimes, IDE extensions) must never be swept by Select All — only
        // safeCache entries are auto-selectable.
        let all = DevLocations.all()
        #expect(all.first { $0.category == "Docker" }?.tier == .askFirst)
        // nvm-installed Node runtimes and IDE extensions are askFirst.
        #expect(all.contains { $0.category == "Node" && $0.path.contains(".nvm/versions/node") && $0.tier == .askFirst })
        #expect(all.contains { $0.category == ".NET" && $0.path.contains(".nuget/packages") && $0.tier == .askFirst })
    }

    @Test func electronEditorCacheDirsAreGenerated() {
        let all = DevLocations.all()
        // Each Electron editor gets its regenerable cache subdirs as safeCache.
        let cursorCache = all.first {
            $0.category == "Cursor" && $0.path.hasSuffix("Application Support/Cursor/Cache")
        }
        #expect(cursorCache?.tier == .safeCache)
        #expect(all.contains { $0.path.hasSuffix("Application Support/Code/GPUCache") })
        #expect(all.contains { $0.path.hasSuffix("Application Support/Windsurf/CachedData") })
    }

    @Test func globEntriesUseWildcards() {
        // Version-/install-specific dirs are carried as glob patterns, expanded
        // at scan time by DevGlob.
        let all = DevLocations.all()
        #expect(all.contains { $0.path.contains("*") })
        #expect(all.contains { $0.path.hasSuffix(".nvm/versions/node/*") })
    }
}

@Suite struct DevGlobTests {
    @Test func expandsImmediateChildren() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devglob-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("v18.0.0"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("v20.11.0"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let matches = DevGlob.expand(root.path + "/*")
        // Trailing-slash from GLOB_MARK is fine — normalize for comparison.
        let names = Set(matches.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(names == ["v18.0.0", "v20.11.0"])
    }

    @Test func expandsPrefixWildcard() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devglob-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("AndroidStudio2024.1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("AndroidStudio2025.1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("OtherApp"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let matches = DevGlob.expand(root.path + "/AndroidStudio*")
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("AndroidStudio") })
    }

    @Test func nonMatchReturnsEmpty() {
        let matches = DevGlob.expand("/nonexistent-\(UUID().uuidString)/*")
        #expect(matches.isEmpty)
    }
}
