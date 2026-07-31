import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewAutomationTests {
    @Test func calendarIntervalsMatchFrequency() {
        let daily = HomebrewSchedule(frequency: .daily, weekday: 7, dayOfMonth: 28, hour: 8, minute: 15)
        let weekly = HomebrewSchedule(frequency: .weekly, weekday: 3, dayOfMonth: 28, hour: 9, minute: 30)
        let monthly = HomebrewSchedule(frequency: .monthly, weekday: 7, dayOfMonth: 12, hour: 10, minute: 45)

        #expect(daily.calendarInterval == ["Hour": 8, "Minute": 15])
        #expect(weekly.calendarInterval == ["Hour": 9, "Minute": 30, "Weekday": 2])
        #expect(monthly.calendarInterval == ["Hour": 10, "Minute": 45, "Day": 12])

        let launchdDays = (1...7).map {
            HomebrewSchedule(frequency: .weekly, weekday: $0).calendarInterval["Weekday"]
        }
        #expect(launchdDays == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func generatedAgentContainsOnlyEnabledSchedulesAndChosenActions() throws {
        let enabled = HomebrewSchedule(frequency: .daily, hour: 7, minute: 5)
        var disabled = HomebrewSchedule(frequency: .monthly, dayOfMonth: 4, hour: 12, minute: 0)
        disabled.isEnabled = false
        let configuration = HomebrewAutomationConfiguration(
            isEnabled: true,
            runUpdate: true,
            runUpgrade: false,
            runCleanup: true,
            schedules: [enabled, disabled]
        )

        let plist = HomebrewAutomation.propertyList(
            configuration: configuration,
            brewPath: "/opt/homebrew/bin/brew",
            askpassPath: "/Applications/BetterCleaner.app/Contents/Resources/homebrew-sudo-askpass"
        )
        let intervals = try #require(plist["StartCalendarInterval"] as? [[String: Int]])
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        let environment = try #require(plist["EnvironmentVariables"] as? [String: String])
        let script = try #require(arguments.last)

        #expect(intervals == [["Hour": 7, "Minute": 5]])
        #expect(Array(arguments.prefix(2)) == ["/bin/sh", "-c"])
        #expect(script.contains("brew' update"))
        #expect(!script.contains("upgrade --greedy"))
        #expect(script.contains("cleanup -s"))
        #expect(script.contains("set -e"))
        #expect(environment["SUDO_ASKPASS"]?.hasSuffix("homebrew-sudo-askpass") == true)
        #expect(environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(environment["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] == "1")
        #expect(environment["SSH_AUTH_SOCK"] == nil)
    }

    @Test func enabledScheduleRequiresAnAction() {
        let configuration = HomebrewAutomationConfiguration(
            isEnabled: true,
            runUpdate: false,
            runUpgrade: false,
            runCleanup: false,
            schedules: [HomebrewSchedule()]
        )
        #expect(throws: HomebrewAutomation.AutomationError.self) {
            try HomebrewAutomation.validate(configuration)
        }
    }

    @Test func greedyCasksRequireExplicitOptInAndNeverQuitApps() {
        var configuration = HomebrewAutomationConfiguration(runUpdate: false, runUpgrade: true)
        let normal = HomebrewAutomation.script(configuration: configuration, brewPath: "/brew", logPath: "/tmp/log")
        #expect(normal.contains("upgrade --no-quit"))
        #expect(!normal.contains("--greedy"))

        configuration.includeAutoUpdatingCasks = true
        let greedy = HomebrewAutomation.script(configuration: configuration, brewPath: "/brew", logPath: "/tmp/log")
        #expect(greedy.contains("upgrade --greedy --no-quit"))
    }

    @Test func invalidCalendarValuesAreRejected() {
        let invalid = HomebrewSchedule(frequency: .monthly, dayOfMonth: 31, hour: 9, minute: 0)
        let configuration = HomebrewAutomationConfiguration(isEnabled: true, schedules: [invalid])
        #expect(throws: HomebrewAutomation.AutomationError.self) {
            try HomebrewAutomation.validate(configuration)
        }
    }

    @Test func generatedScriptActuallyRunsWithPOSIXShell() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCleaner-Automation-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let configuration = HomebrewAutomationConfiguration(
            isEnabled: true, runUpdate: true, runUpgrade: true, runCleanup: true,
            schedules: [HomebrewSchedule()]
        )
        let script = HomebrewAutomation.script(
            configuration: configuration, brewPath: "/usr/bin/true", logPath: log.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func failedReplacementRestoresPreviousAgent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCleaner-Automation-\(UUID().uuidString)")
        let agent = directory.appendingPathComponent("agent.plist")
        let log = directory.appendingPathComponent("log.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Data("previous plist".utf8)
        try previous.write(to: agent)

        var loaded = true
        var bootstrapCount = 0
        let launchctl: HomebrewAutomation.Launchctl = { arguments in
            switch arguments.first {
            case "print": return Self.output(loaded ? 0 : 3, loaded ? "state = waiting" : "not found")
            case "bootout": loaded = false; return Self.output(0)
            case "bootstrap":
                bootstrapCount += 1
                if bootstrapCount == 1 { return Self.output(5, "new job rejected") }
                loaded = true
                return Self.output(0)
            default: return Self.output(64, "unexpected")
            }
        }

        #expect(throws: HomebrewAutomation.AutomationError.self) {
            try HomebrewAutomation.replaceAgent(
                propertyList: ["Label": "replacement"], targetAgentURL: agent,
                targetLogURL: log, launchctl: launchctl, pause: { _ in }
            )
        }
        #expect(try Data(contentsOf: agent) == previous)
        #expect(loaded)
        #expect(bootstrapCount == 2)
    }

    @Test func runningAgentCannotBeReconfiguredOrDisabled() throws {
        var commands: [[String]] = []
        let launchctl: HomebrewAutomation.Launchctl = { arguments in
            commands.append(arguments)
            return Self.output(0, "state = running")
        }
        #expect(throws: HomebrewAutomation.AutomationError.self) {
            try HomebrewAutomation.replaceAgent(
                propertyList: nil,
                targetAgentURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                launchctl: launchctl,
                pause: { _ in }
            )
        }
        #expect(commands.count == 1)
        #expect(commands.first?.first == "print")
    }

    private static func output(_ status: Int32, _ message: String = "") -> CommandRunner.Output {
        CommandRunner.Output(status: status, stdout: message, stderr: "")
    }
}
