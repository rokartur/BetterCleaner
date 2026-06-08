import Foundation

/// Finds removable `.lproj` localization folders inside app bundles, keeping the
/// user's preferred languages plus English and Base.
enum LocalizationPruner {
    /// Lowercased language codes that must never be removed.
    static func keepCodes() -> Set<String> {
        var keep: Set<String> = ["base", "en", "english"]
        for language in Locale.preferredLanguages {
            let lower = language.lowercased()
            keep.insert(lower)
            keep.insert(lower.replacingOccurrences(of: "-", with: "_"))
            if let base = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
                keep.insert(String(base))
            }
        }
        return keep
    }

    /// Whether a `.lproj` folder should be kept (not offered for removal).
    static func shouldKeep(lprojName: String, keep: Set<String>) -> Bool {
        let code = lprojName.replacingOccurrences(of: ".lproj", with: "").lowercased()
        if keep.contains(code) { return true }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return keep.contains(base)
    }

    /// Scan installed apps for removable language folders, grouped per app.
    static func scan(apps: [InstalledApp], keep: Set<String>) -> [ScanSection] {
        let fm = FileManager.default
        var sections: [ScanSection] = []

        for app in apps {
            let resources = app.url.appendingPathComponent("Contents/Resources", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: resources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            var items: [FileItem] = []
            for url in entries where url.pathExtension == "lproj" {
                if shouldKeep(lprojName: url.lastPathComponent, keep: keep) { continue }
                let size = FileSize.size(of: url)
                items.append(FileItem(
                    url: url,
                    category: app.name,
                    domain: app.isSystem ? .system : .user,
                    isDirectory: true,
                    size: size,
                    isSelected: false
                ))
            }

            if !items.isEmpty {
                sections.append(ScanSection(category: app.name, items: items.sorted { $0.size > $1.size }))
            }
        }
        return sections.sorted { $0.totalSize > $1.totalSize }
    }
}
