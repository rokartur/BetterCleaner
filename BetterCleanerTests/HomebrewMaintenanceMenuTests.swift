import AppKit
import Testing
@testable import BetterCleaner

@Suite @MainActor struct HomebrewMaintenanceMenuTests {
    @Test func preparationRetainsMenuUntilCompletion() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var menu: HomebrewMaintenanceMenu? = HomebrewMaintenanceMenu(
            presenter: NSViewController(),
            onChanged: {},
            onOpenPage: { _ in }
        )
        weak var weakMenu = menu

        await withCheckedContinuation { continuation in
            menu?.performPreparation({
                started.signal()
                release.wait()
                return 42
            }) { result in
                #expect((try? result.get()) == 42)
                continuation.resume()
            }

            started.wait()
            menu = nil
            #expect(weakMenu != nil)
            release.signal()
        }

        await Task.yield()
        #expect(weakMenu == nil)
    }
}
