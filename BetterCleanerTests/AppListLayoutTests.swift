import AppKit
import Testing
@testable import BetterCleaner

@MainActor
@Suite struct AppListLayoutTests {
    @Test func filterControlsAreBelowTheTitleBar() throws {
        let windowController = MainWindowController()
        let window = try #require(windowController.window)
        let contentView = try #require(window.contentView)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let searchField = try #require(contentView.descendants.compactMap { $0 as? NSSearchField }.first)
        let searchFrame = searchField.convert(searchField.bounds, to: contentView)

        #expect(searchFrame.maxY <= window.contentLayoutRect.height)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
