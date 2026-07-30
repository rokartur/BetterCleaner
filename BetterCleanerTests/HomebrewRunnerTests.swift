import Foundation
import Testing
@testable import BetterCleaner

@Suite struct HomebrewRunnerTests {
    @Test func failureSkipsRemainingRequiredStepsAndRunsFinalizer() async throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCleaner-HomebrewRunner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }

        let plan = HomebrewCommandPlan(steps: [
            .required(["-c", "printf A >> \(log.path)"]),
            .required(["-c", "exit 1"]),
            .required(["-c", "printf B >> \(log.path)"]),
            .finally(["-c", "printf F >> \(log.path)"]),
        ])
        let runner = HomebrewRunner(executablePath: "/bin/sh", environment: ProcessInfo.processInfo.environment)
        let success = await withCheckedContinuation { continuation in
            runner.run(plan, onLine: { _ in }) { continuation.resume(returning: $0) }
        }

        #expect(!success)
        #expect(try String(contentsOf: log, encoding: .utf8) == "AF")
    }

    @Test func cancellationStopsRequiredStepsButRunsFinalizer() async throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterCleaner-HomebrewRunner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }

        let plan = HomebrewCommandPlan(steps: [
            .required(["-c", "printf A >> \(log.path)"]),
            .required(["-c", "echo started; exec /bin/sleep 30"]),
            .required(["-c", "printf B >> \(log.path)"]),
            .finally(["-c", "printf F >> \(log.path)"]),
        ])
        let runner = HomebrewRunner(executablePath: "/bin/sh", environment: ProcessInfo.processInfo.environment)
        let success = await withCheckedContinuation { continuation in
            runner.run(plan, onLine: { line in
                if line == "started" { runner.cancel() }
            }) { continuation.resume(returning: $0) }
        }

        #expect(!success)
        #expect(try String(contentsOf: log, encoding: .utf8) == "AF")
    }
}
