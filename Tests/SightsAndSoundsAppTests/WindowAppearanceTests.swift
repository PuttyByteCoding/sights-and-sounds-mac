import AppKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// The app's windows paint charcoal surfaces; their native chrome —
/// title bar, menus, alerts, pickers — follows the window's appearance.
/// On a Mac in Light mode that chrome came out light on dark. Every
/// window but Settings is dark whatever the system says.
@Suite(.serialized) @MainActor struct WindowAppearanceTests {
    private func appearance(of view: some View) -> NSAppearance.Name? {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    }

    @Test func anAppWindowIsDarkOnALightMac() {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        defer { NSApplication.shared.appearance = previous }

        #expect(appearance(of: Color.clear) == .aqua, "the test really is on a light Mac")
        #expect(appearance(of: Color.clear.appWindowAppearance()) == .darkAqua)
    }
}
