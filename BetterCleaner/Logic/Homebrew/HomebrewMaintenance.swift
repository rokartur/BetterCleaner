import Foundation

struct HomebrewDoctorReport: Equatable {
    let exitStatus: Int32
    let output: String

    var isHealthy: Bool { exitStatus == 0 }
}

struct HomebrewMaintenanceStats: Equatable {
    var installed: Int? = nil
    var outdated: Int? = nil
    var services: Int? = nil
    var taps: Int? = nil
}

struct HomebrewMaintenanceSnapshot {
    let isInstalled: Bool
    var currentVersion: String?
    var latestVersion: String?
    var doctor: HomebrewDoctorReport?
    var cacheBytes: Int64?
    var analyticsEnabled: Bool?
    var stats: HomebrewMaintenanceStats
    var errors: [String]

    var isUpdateAvailable: Bool {
        guard let currentVersion, let latestVersion else { return false }
        return HomebrewMaintenance.isUpdateAvailable(current: currentVersion, latest: latestVersion)
    }
}

enum HomebrewMaintenanceError: LocalizedError, Equatable {
    case notInstalled
    case commandFailed(arguments: [String], status: Int32, message: String)
    case latestReleaseRequestFailed(status: Int)
    case invalidLatestRelease
    case unknownAnalyticsState

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Homebrew is not installed."
        case .commandFailed(let arguments, let status, let message):
            let detail = message.isEmpty ? "brew exited with status \(status)." : message
            return "brew \(arguments.joined(separator: " ")) failed: \(detail)"
        case .latestReleaseRequestFailed(let status):
            return "GitHub returned HTTP \(status) while checking the latest Homebrew release."
        case .invalidLatestRelease:
            return "GitHub returned an unreadable Homebrew release."
        case .unknownAnalyticsState:
            return "Homebrew returned an unknown analytics state."
        }
    }
}

/// Read-only Homebrew health and maintenance data, plus the small analytics
/// mutation. Long-running update/cleanup commands remain in `HomebrewRunner` so
/// callers can stream progress and cancel them.
enum HomebrewMaintenance {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!

    /// Returns as much data as could be loaded. Individual failures are kept in
    /// `errors` so a GitHub outage, for example, does not hide local brew health.
    static func loadSnapshot(session: URLSession = .shared) async -> HomebrewMaintenanceSnapshot {
        guard let brewPath = HomebrewEnvironment.brewPath else {
            return HomebrewMaintenanceSnapshot(
                isInstalled: false,
                currentVersion: nil,
                latestVersion: nil,
                doctor: nil,
                cacheBytes: nil,
                analyticsEnabled: nil,
                stats: HomebrewMaintenanceStats(),
                errors: [HomebrewMaintenanceError.notInstalled.localizedDescription]
            )
        }

        async let latestResult = fetchLatestVersion(session: session)
        let local = await Task.detached(priority: .userInitiated) {
            loadLocalSnapshot(brewPath: brewPath)
        }.value

        var snapshot = local
        switch await latestResult {
        case .success(let version):
            snapshot.latestVersion = version
        case .failure(let error):
            snapshot.errors.append("Latest version: \(error.localizedDescription)")
        }
        return snapshot
    }

    /// A focused doctor refresh used by the maintenance page's Run Doctor button.
    /// A non-zero status is a valid report (it means doctor found problems), not a
    /// transport error, so it is returned with the complete output intact.
    static func runDoctor() async throws -> HomebrewDoctorReport {
        guard let brewPath = HomebrewEnvironment.brewPath else {
            throw HomebrewMaintenanceError.notInstalled
        }
        let output = await Task.detached(priority: .userInitiated) {
            CommandRunner.run(brewPath, ["doctor"], environment: readOnlyEnvironment())
        }.value
        if output.status == -1 {
            throw commandError(arguments: ["doctor"], output: output)
        }
        return doctorReport(from: output)
    }

    /// Persists the requested Homebrew analytics preference, then reads it back.
    /// BetterCleaner's normal brew environment disables analytics for its own
    /// commands; these calls deliberately remove that process-only override so the
    /// user's actual Homebrew preference can be inspected and changed.
    static func setAnalytics(enabled: Bool) async throws -> Bool {
        guard let brewPath = HomebrewEnvironment.brewPath else {
            throw HomebrewMaintenanceError.notInstalled
        }
        return try await Task.detached(priority: .userInitiated) {
            let arguments = ["analytics", enabled ? "on" : "off"]
            let environment = analyticsEnvironment()
            let mutation = CommandRunner.run(brewPath, arguments, environment: environment)
            guard mutation.ok else { throw commandError(arguments: arguments, output: mutation) }

            let stateArguments = ["analytics", "state"]
            let state = CommandRunner.run(brewPath, stateArguments, environment: environment)
            guard state.ok else { throw commandError(arguments: stateArguments, output: state) }
            guard let actual = parseAnalyticsState(state.stdout + "\n" + state.stderr) else {
                throw HomebrewMaintenanceError.unknownAnalyticsState
            }
            return actual
        }.value
    }

    // MARK: - Parsers (kept internal for focused tests)

    static func parseCurrentVersion(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("homebrew ") else { continue }
            let value = line.dropFirst("Homebrew ".count)
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            return normalizedVersion(value)
        }
        return nil
    }

    static func parseLatestVersion(_ data: Data) throws -> String {
        struct Release: Decodable {
            let tagName: String
            enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        }

        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let version = normalizedVersion(release.tagName) else {
            throw HomebrewMaintenanceError.invalidLatestRelease
        }
        return version
    }

    static func parseAnalyticsState(_ output: String) -> Bool? {
        let value = output.lowercased()
        if value.contains("analytics are disabled") || value.contains("analytics is disabled") {
            return false
        }
        if value.contains("analytics are enabled") || value.contains("analytics is enabled") {
            return true
        }
        return nil
    }

    static func isUpdateAvailable(current: String, latest: String) -> Bool {
        guard !current.isEmpty, !latest.isEmpty else { return false }
        return HomebrewVersion.compare(current, latest) == .orderedAscending
    }

    static func doctorReport(from output: CommandRunner.Output) -> HomebrewDoctorReport {
        HomebrewDoctorReport(exitStatus: output.status, output: combinedOutput(output))
    }

    static func parseCacheURL(_ output: String) -> URL? {
        guard let path = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    // MARK: - Snapshot assembly

    private static func loadLocalSnapshot(brewPath: String) -> HomebrewMaintenanceSnapshot {
        let environment = readOnlyEnvironment()
        var snapshot = HomebrewMaintenanceSnapshot(
            isInstalled: true,
            currentVersion: nil,
            latestVersion: nil,
            doctor: nil,
            cacheBytes: nil,
            analyticsEnabled: nil,
            stats: HomebrewMaintenanceStats(),
            errors: []
        )

        let versionArguments = ["--version"]
        let version = CommandRunner.run(brewPath, versionArguments, environment: environment)
        if version.ok, let parsed = parseCurrentVersion(version.stdout + "\n" + version.stderr) {
            snapshot.currentVersion = parsed
        } else if version.ok {
            snapshot.errors.append("Current version: Homebrew returned an unreadable version.")
        } else {
            snapshot.errors.append("Current version: \(commandError(arguments: versionArguments, output: version).localizedDescription)")
        }

        let doctorArguments = ["doctor"]
        let doctor = CommandRunner.run(brewPath, doctorArguments, environment: environment)
        if doctor.status == -1 {
            snapshot.errors.append("Doctor: \(commandError(arguments: doctorArguments, output: doctor).localizedDescription)")
        } else {
            snapshot.doctor = doctorReport(from: doctor)
        }

        let cacheArguments = ["--cache"]
        let cache = CommandRunner.run(brewPath, cacheArguments, environment: environment)
        if cache.ok, let cacheURL = parseCacheURL(cache.stdout) {
            let size = FileSize.sizeWithStatus(of: cacheURL)
            snapshot.cacheBytes = size.bytes
            if !size.complete {
                snapshot.errors.append("Cache size: Some files could not be read, so the displayed size is a lower bound.")
            }
        } else if cache.ok {
            snapshot.errors.append("Cache size: Homebrew returned an unreadable cache path.")
        } else {
            snapshot.errors.append("Cache size: \(commandError(arguments: cacheArguments, output: cache).localizedDescription)")
        }

        let analyticsArguments = ["analytics", "state"]
        let analytics = CommandRunner.run(brewPath, analyticsArguments, environment: analyticsEnvironment())
        if analytics.ok {
            snapshot.analyticsEnabled = parseAnalyticsState(analytics.stdout + "\n" + analytics.stderr)
            if snapshot.analyticsEnabled == nil {
                snapshot.errors.append("Analytics: \(HomebrewMaintenanceError.unknownAnalyticsState.localizedDescription)")
            }
        } else {
            snapshot.errors.append("Analytics: \(commandError(arguments: analyticsArguments, output: analytics).localizedDescription)")
        }

        do {
            let packages = try HomebrewService.installedPackages()
            snapshot.stats.installed = packages.count
            snapshot.stats.outdated = packages.filter(\.isOutdated).count
        } catch {
            snapshot.errors.append("Installed packages: \(error.localizedDescription)")
        }

        do {
            snapshot.stats.services = try HomebrewService.services().count
        } catch {
            snapshot.errors.append("Services: \(error.localizedDescription)")
        }

        do {
            snapshot.stats.taps = try HomebrewService.taps().count
        } catch {
            snapshot.errors.append("Taps: \(error.localizedDescription)")
        }

        return snapshot
    }

    private static func fetchLatestVersion(session: URLSession) async -> Result<String, Error> {
        do {
            var request = URLRequest(url: latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("BetterCleaner", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw HomebrewMaintenanceError.latestReleaseRequestFailed(status: response.statusCode)
            }
            return .success(try parseLatestVersion(data))
        } catch {
            return .failure(error)
        }
    }

    private static func readOnlyEnvironment() -> [String: String] {
        HomebrewEnvironment.environment(includeAskpass: false)
    }

    private static func analyticsEnvironment() -> [String: String] {
        var environment = HomebrewEnvironment.environment(includeAskpass: false)
        environment.removeValue(forKey: "HOMEBREW_NO_ANALYTICS")
        environment.removeValue(forKey: "HOMEBREW_NO_ANALYTICS_THIS_RUN")
        return environment
    }

    private static func commandError(arguments: [String], output: CommandRunner.Output) -> HomebrewMaintenanceError {
        let message = (output.stderr.isEmpty ? output.stdout : output.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(arguments: arguments, status: output.status, message: message)
    }

    private static func combinedOutput(_ output: CommandRunner.Output) -> String {
        switch (output.stdout.isEmpty, output.stderr.isEmpty) {
        case (false, false):
            return output.stdout + (output.stdout.hasSuffix("\n") ? "" : "\n") + output.stderr
        case (false, true):
            return output.stdout
        case (true, false):
            return output.stderr
        case (true, true):
            return ""
        }
    }

    private static func normalizedVersion(_ value: String) -> String? {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard version.first?.isNumber == true else { return nil }
        return version
    }
}
