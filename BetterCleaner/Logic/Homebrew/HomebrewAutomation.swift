import Foundation

enum HomebrewScheduleFrequency: String, Codable, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
}

struct HomebrewSchedule: Codable, Equatable, Identifiable {
    var id = UUID()
    var frequency: HomebrewScheduleFrequency = .weekly
    /// Calendar weekday (1 = Sunday ... 7 = Saturday).
    var weekday = 2
    var dayOfMonth = 1
    var hour = 9
    var minute = 0
    var isEnabled = true

    var calendarInterval: [String: Int] {
        var interval = ["Hour": hour, "Minute": minute]
        switch frequency {
        case .daily: break
        case .weekly: interval["Weekday"] = (weekday + 6) % 7
        case .monthly: interval["Day"] = dayOfMonth
        }
        return interval
    }
}

struct HomebrewAutomationConfiguration: Codable, Equatable {
    var isEnabled = false
    var runUpdate = true
    var runUpgrade = true
    var includeAutoUpdatingCasks = false
    var runCleanup = false
    var schedules: [HomebrewSchedule] = []

    var hasAction: Bool { runUpdate || runUpgrade || runCleanup }
    var enabledSchedules: [HomebrewSchedule] { schedules.filter(\.isEnabled) }
}

/// Persists automatic Homebrew maintenance and mirrors it to one per-user LaunchAgent.
/// Schedules share one action set, matching Homebrew's native update -> upgrade -> cleanup
/// order and keeping the generated job small enough to inspect by hand.
enum HomebrewAutomation {
    enum AutomationError: LocalizedError {
        case invalidSchedule(String)
        case noActions
        case homebrewMissing
        case writeFailed(String)
        case launchctlFailed(String)
        case agentRunning

        var errorDescription: String? {
            switch self {
            case .invalidSchedule(let message): return message
            case .noActions: return "Choose at least one automatic action."
            case .homebrewMissing: return "Homebrew is not installed."
            case .writeFailed(let message): return "Couldn't save the Homebrew schedule: \(message)"
            case .launchctlFailed(let message): return "Couldn't activate the Homebrew schedule: \(message)"
            case .agentRunning: return "Automatic Homebrew maintenance is running. Wait for it to finish before changing or disabling its schedule."
            }
        }
    }

    static var label: String {
        "\(Bundle.main.bundleIdentifier ?? "com.rokartur.BetterCleaner").homebrew-auto-update"
    }
    static let defaultsKey = "HomebrewAutomationConfiguration"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BetterCleaner/HomebrewAutoUpdate.log")
    }

    static func load(defaults: UserDefaults = .standard) -> HomebrewAutomationConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(HomebrewAutomationConfiguration.self, from: data)
        else { return HomebrewAutomationConfiguration() }
        return configuration
    }

    static func apply(_ configuration: HomebrewAutomationConfiguration,
                      defaults: UserDefaults = .standard) throws {
        try validate(configuration)

        let encoded: Data
        do { encoded = try JSONEncoder().encode(configuration) }
        catch { throw AutomationError.writeFailed(error.localizedDescription) }

        if configuration.isEnabled, !configuration.enabledSchedules.isEmpty {
            guard let brew = HomebrewEnvironment.brewPath else { throw AutomationError.homebrewMissing }
            try replaceAgent(propertyList: propertyList(configuration: configuration, brewPath: brew))
        } else {
            try replaceAgent(propertyList: nil)
        }
        defaults.set(encoded, forKey: defaultsKey)
    }

    static func validate(_ configuration: HomebrewAutomationConfiguration) throws {
        if configuration.isEnabled, !configuration.enabledSchedules.isEmpty, !configuration.hasAction {
            throw AutomationError.noActions
        }
        for schedule in configuration.schedules {
            guard (0...23).contains(schedule.hour), (0...59).contains(schedule.minute) else {
                throw AutomationError.invalidSchedule("Schedule time is outside the valid range.")
            }
            if schedule.frequency == .weekly, !(1...7).contains(schedule.weekday) {
                throw AutomationError.invalidSchedule("Weekly schedules need a valid weekday.")
            }
            if schedule.frequency == .monthly, !(1...28).contains(schedule.dayOfMonth) {
                throw AutomationError.invalidSchedule("Monthly schedules use days 1 through 28.")
            }
        }
    }

    /// Pure plist builder, kept internal so tests can verify the exact launchd contract.
    static func propertyList(configuration: HomebrewAutomationConfiguration,
                             brewPath: String,
                             askpassPath: String? = HomebrewEnvironment.askpassPath) -> [String: Any] {
        let command = script(configuration: configuration, brewPath: brewPath)
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": HomebrewEnvironment.environment(includeAskpass: false)["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_NO_ASK": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_COLOR": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_UPGRADE_QUIT_CASKS": "1",
        ]
        if let askpassPath {
            environment["SUDO_ASKPASS"] = askpassPath
        }

        return [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", command],
            "EnvironmentVariables": environment,
            "RunAtLoad": false,
            "StartCalendarInterval": configuration.enabledSchedules.map(\.calendarInterval),
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Background",
        ]
    }

    static func script(configuration: HomebrewAutomationConfiguration, brewPath: String,
                       logPath: String = HomebrewAutomation.logURL.path) -> String {
        let brew = PrivilegedRunner.quote(brewPath)
        var commands = [
            ": > \(PrivilegedRunner.quote(logPath))",
            "set -e",
            "trap 'code=$?; echo \"=== Finished — $(date) (exit $code) ===\"; exit $code' EXIT",
            "echo '=== BetterCleaner Homebrew — '$(date)' ==='",
        ]
        if configuration.runUpdate {
            commands.append("\(brew) update")
        }
        if configuration.runUpgrade {
            commands.append("\(brew) upgrade\(configuration.includeAutoUpdatingCasks ? " --greedy" : "") --no-quit")
        }
        if configuration.runCleanup {
            commands.append("\(brew) autoremove")
            commands.append("\(brew) cleanup -s")
        }
        return commands.joined(separator: "; ")
    }

    typealias Launchctl = ([String]) -> CommandRunner.Output

    static func isAgentLoaded(launchctl: Launchctl = runLaunchctl) -> Bool {
        launchctl(["print", serviceTarget]).ok
    }

    static func isAgentRunning(launchctl: Launchctl = runLaunchctl) -> Bool {
        let output = launchctl(["print", serviceTarget])
        return output.ok && (output.stdout + output.stderr).contains("state = running")
    }

    /// Atomically replaces the LaunchAgent and restores the previous plist/job if
    /// writing or bootstrapping the replacement fails.
    static func replaceAgent(propertyList: [String: Any]?,
                             targetAgentURL: URL = HomebrewAutomation.agentURL,
                             targetLogURL: URL = HomebrewAutomation.logURL,
                             launchctl: Launchctl = runLaunchctl,
                             pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        let fm = FileManager.default
        let previousData = try? Data(contentsOf: targetAgentURL)
        let state = launchctl(["print", serviceTarget])
        let wasLoaded = state.ok
        if wasLoaded, (state.stdout + state.stderr).contains("state = running") {
            throw AutomationError.agentRunning
        }

        let replacement: Data?
        do {
            replacement = try propertyList.map {
                try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0)
            }
            if replacement != nil {
                try fm.createDirectory(at: targetAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createDirectory(at: targetLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
        } catch {
            throw AutomationError.writeFailed(error.localizedDescription)
        }

        do {
            if wasLoaded { try unloadAgent(launchctl: launchctl, pause: pause) }
            if let replacement {
                do { try replacement.write(to: targetAgentURL, options: .atomic) }
                catch { throw AutomationError.writeFailed(error.localizedDescription) }
                try bootstrapAgent(at: targetAgentURL, launchctl: launchctl)
            } else if fm.fileExists(atPath: targetAgentURL.path) {
                do { try fm.removeItem(at: targetAgentURL) }
                catch { throw AutomationError.writeFailed(error.localizedDescription) }
            }
        } catch {
            do {
                if isAgentLoaded(launchctl: launchctl) {
                    try unloadAgent(launchctl: launchctl, pause: pause)
                }
                if let previousData {
                    try previousData.write(to: targetAgentURL, options: .atomic)
                    if wasLoaded { try bootstrapAgent(at: targetAgentURL, launchctl: launchctl) }
                } else if fm.fileExists(atPath: targetAgentURL.path) {
                    try fm.removeItem(at: targetAgentURL)
                }
            } catch let rollbackError {
                throw AutomationError.launchctlFailed(
                    "\(error.localizedDescription) Rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    private static var domainTarget: String { "gui/\(getuid())" }

    private static func runLaunchctl(_ arguments: [String]) -> CommandRunner.Output {
        CommandRunner.run("/bin/launchctl", arguments)
    }

    private static func bootstrapAgent(at url: URL, launchctl: Launchctl) throws {
        let output = launchctl(["bootstrap", domainTarget, url.path])
        guard output.ok else { throw AutomationError.launchctlFailed(message(from: output)) }
    }

    private static func unloadAgent(launchctl: Launchctl,
                                    pause: (TimeInterval) -> Void) throws {
        let output = launchctl(["bootout", serviceTarget])
        guard output.ok else { throw AutomationError.launchctlFailed(message(from: output)) }
        for _ in 0..<20 {
            if !launchctl(["print", serviceTarget]).ok { return }
            pause(0.05)
        }
        throw AutomationError.launchctlFailed("launchd kept the previous job loaded.")
    }

    private static func message(from output: CommandRunner.Output) -> String {
        let text = output.stderr.isEmpty ? output.stdout : output.stderr
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "launchctl exited with status \(output.status)." : message
    }
}
