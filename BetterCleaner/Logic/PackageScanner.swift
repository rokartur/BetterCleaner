import Foundation

struct PackageReceipt {
    let id: String
    let version: String
    let installLocation: String
    /// When the package was installed (from the receipt's `install-time`).
    let installDate: Date?

    init(id: String, version: String, installLocation: String, installDate: Date? = nil) {
        self.id = id
        self.version = version
        self.installLocation = installLocation
        self.installDate = installDate
    }
}

/// Lists installed package receipts via `pkgutil`/`lsbom`, lists the files each
/// package installed (its Bill of Materials), forgets receipts, and removes the
/// installed files (to the Trash). Stays on public CLI tools — no private
/// PackageKit framework — to keep BetterCleaner native and distribution-safe.
enum PackageScanner {
    private static let pkgutil = "/usr/sbin/pkgutil"
    private static let lsbom = "/usr/bin/lsbom"
    private static let receiptsDir = "/var/db/receipts"

    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: pkgutil)
    }

    /// Non-Apple package ids only (the ids `scan()` would surface), without the
    /// per-id `--pkg-info` spawns — for callers that just need the id list, such as
    /// the orphan-receipt audit.
    static func nonSystemPackageIDs() -> [String] {
        guard isAvailable() else { return [] }
        let list = CommandRunner.run(pkgutil, ["--pkgs"])
        guard list.ok else { return [] }
        return parsePackageList(list.stdout).filter { !isSystemPackage(id: $0) }
    }

    static func scan() -> [PackageReceipt] {
        let list = CommandRunner.run(pkgutil, ["--pkgs"])
        guard list.ok else { return [] }

        let ids = parsePackageList(list.stdout).filter { !isSystemPackage(id: $0) }
        // Each `pkgutil --pkg-info` is an independent Process spawn; run them
        // concurrently and write each result into its own slot (index writes are
        // data-race-free) instead of N serial spawns.
        var slots = [PackageReceipt?](repeating: nil, count: ids.count)
        slots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let id = ids[index]
                let info = CommandRunner.run(pkgutil, ["--pkg-info", id]).stdout
                let parsed = parsePkgInfo(info)
                buffer[index] = PackageReceipt(id: id, version: parsed.version, installLocation: parsed.location, installDate: installDate(fromPkgInfo: info))
            }
        }
        return slots.compactMap { $0 }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Receipts macOS installs itself — hidden from the Packages list. These live
    /// in the OS installer namespace `com.apple.pkg.*` (Command Line Tools,
    /// XProtect, Rosetta, SDKs…) and the `com.apple.files.*` system templates.
    ///
    /// NOT every `com.apple.*` id: Apple tools the user installs separately keep
    /// their own ids (e.g. `com.apple.container-installer`) and must still show.
    static func isSystemPackage(id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("com.apple.pkg.") || lower.hasPrefix("com.apple.files.")
    }

    // MARK: - Bill of Materials (installed files)

    /// The absolute, safety-filtered paths a package installed, derived from its
    /// `.bom` via `lsbom` and made absolute against the receipt's install root.
    /// Read-only; needs Full Disk Access to read `/var/db/receipts`.
    static func bomFiles(id: String) -> [URL] {
        PackageBOMFilter.filter(rawBOMFiles(id: id).map(\.path))
            .map { URL(fileURLWithPath: $0) }
    }

    /// Uncollapsed BOM paths. Package ownership needs these to discover every
    /// top-level `.app` before a parent directory collapses its descendants.
    static func rawBOMFiles(id: String, isCancelled: (() -> Bool)? = nil) -> [URL] {
        let bomPath = "\(receiptsDir)/\(id).bom"
        guard FileManager.default.fileExists(atPath: bomPath),
              FileManager.default.isExecutableFile(atPath: lsbom) else { return [] }
        // Without the install root every path would be resolved against "/", so a
        // failed lookup has to abort rather than invent an ownership claim.
        let pkgInfo = CommandRunner.run(pkgutil, ["--pkg-info", id], isCancelled: isCancelled)
        guard pkgInfo.ok else { return [] }
        let root = installRoot(fromPkgInfo: pkgInfo.stdout)
        let out = CommandRunner.run(lsbom, ["-p", "f", bomPath], isCancelled: isCancelled)
        guard out.ok else { return [] }
        return absolutePaths(fromLsbom: out.stdout, root: root).map { URL(fileURLWithPath: $0) }
    }

    /// Make `lsbom -p f` relative paths (`./Applications/Foo.app`) absolute under
    /// the install `root`. Pure; unit-tested.
    static func absolutePaths(fromLsbom text: String, root: String) -> [String] {
        var result: [String] = []
        for raw in text.split(separator: "\n") {
            var rel = raw.trimmingCharacters(in: .whitespaces)
            guard !rel.isEmpty, rel != "." else { continue }
            if rel.hasPrefix("./") { rel.removeFirst(2) }
            result.append((root as NSString).appendingPathComponent(rel))
        }
        return result
    }

    /// The installed files of `id` as `FileItem`s, pre-selected, with domain
    /// inferred from the path (anything outside the user's home is system-owned).
    static func fileItems(id: String) -> [FileItem] {
        let home = NSHomeDirectory()
        return bomFiles(id: id).map { url in
            let isUser = url.path.hasPrefix(home + "/")
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let (size, complete) = FileSize.sizeWithStatus(of: url)
            return FileItem(url: url, category: "Package Files", domain: isUser ? .user : .system,
                            isDirectory: isDir.boolValue, size: size, isSelected: true, sizeIsApproximate: !complete)
        }
    }

    /// The receipt files (`.plist` + `.bom`) backing a package id.
    static func receiptPaths(id: String) -> [URL] {
        ["\(receiptsDir)/\(id).plist", "\(receiptsDir)/\(id).bom"]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Package ids from `pkgutil --pkgs`, one per line (blanks dropped).
    static func parsePackageList(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `version:` / `location:` fields from `pkgutil --pkg-info`.
    static func parsePkgInfo(_ text: String) -> (version: String, location: String) {
        (parseField(text, "version"), parseField(text, "location"))
    }

    /// Value of a single `field:` line in `pkgutil --pkg-info` output.
    static func parseField(_ text: String, _ field: String) -> String {
        let prefix = field + ":"
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// The install root (`volume` + `location`) BOM paths are relative to.
    static func installRoot(fromPkgInfo text: String) -> String {
        let volume = parseField(text, "volume")
        let location = parseField(text, "location")
        let base = volume.isEmpty ? "/" : volume
        return (base as NSString).appendingPathComponent(location)
    }

    /// The receipt's `install-time` (Unix epoch seconds) as a `Date`.
    static func installDate(fromPkgInfo text: String) -> Date? {
        let raw = parseField(text, "install-time")
        guard let secs = TimeInterval(raw), secs > 0 else { return nil }
        return Date(timeIntervalSince1970: secs)
    }

    /// Forget the given receipt ids in one admin batch. Returns an error string
    /// on failure, nil on success.
    static func forget(ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        // ';' so each forget is independent within the single admin prompt.
        let command = ids
            .map { "\(pkgutil) --forget \(PrivilegedRunner.quote($0))" }
            .joined(separator: " ; ")
        do {
            try PrivilegedRunner.runAdminCommand(command)
            return nil
        } catch PrivilegedRunner.RunError.cancelled {
            return "cancelled"
        } catch {
            return "\(error)"
        }
    }
}
