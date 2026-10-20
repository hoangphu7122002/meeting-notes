import AppKit
import MeetingNotesUI
import SwiftUI
import Testing

@Suite("Window hosting")
@MainActor
struct WindowHostingTests {
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// Regression: a fresh NSWindow has a plain NSView content view, which left the main window blank.
    @Test func installsIntoFreshWindow() {
        let window = makeWindow()
        #expect(window.contentView != nil)
        let installed = window.hostContentIfNeeded { NSHostingView(rootView: Text("x")) }
        #expect(installed)
        #expect(window.contentView is NSHostingView<Text>)
    }

    @Test func keepsExistingHostingView() {
        let window = makeWindow()
        window.hostContentIfNeeded { NSHostingView(rootView: Text("x")) }
        let first = window.contentView
        let installed = window.hostContentIfNeeded { NSHostingView(rootView: Text("y")) }
        #expect(!installed)
        #expect(window.contentView === first)
    }

    @Test func reinstallsAfterRelease() {
        let window = makeWindow()
        window.hostContentIfNeeded { NSHostingView(rootView: Text("x")) }
        window.contentView = nil
        #expect(window.hostContentIfNeeded { NSHostingView(rootView: Text("x")) })
        #expect(window.contentView is NSHostingView<Text>)
    }
}
