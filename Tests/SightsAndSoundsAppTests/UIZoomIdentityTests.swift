import AppKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// Zooming must not rebuild a window's content. At 1.0 the modifier
/// used to return `content` from one branch and a GeometryReader from
/// the other, so crossing 1.0 gave the content a new identity — and a
/// library window's @State model, filter, selection and playing video
/// with it.
@Suite(.serialized) @MainActor struct UIZoomIdentityTests {
    /// Every @State identity the probe has appeared with.
    static var appearances: [UUID] = []

    private struct Probe: View {
        @State private var identity = UUID()
        var body: some View {
            Color.clear.onAppear { UIZoomIdentityTests.appearances.append(identity) }
        }
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    @Test func crossingOneToOneKeepsTheContentsState() {
        UIZoom.shared.reset()
        Self.appearances = []
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Probe().uiZoomed())
        window.orderFront(nil)
        defer { window.close(); UIZoom.shared.reset() }
        spin()

        UIZoom.shared.zoomIn()
        spin()
        UIZoom.shared.reset()
        spin()

        #expect(Self.appearances.count >= 1)
        #expect(Set(Self.appearances).count == 1)
    }

    static var laidOut: CGSize = .zero

    private struct Measure: View {
        var body: some View {
            Color.clear.onGeometryChange(for: CGSize.self, of: { $0.size }) {
                UIZoomIdentityTests.laidOut = $0
            }
        }
    }

    /// Zoomed in, the content lays out at the smaller logical size and
    /// is drawn scaled up to fill the window — text reflows, nothing is
    /// cropped.
    @Test func zoomedContentLaysOutAtTheShrunkenSize() {
        UIZoom.shared.reset()
        UIZoom.shared.zoomIn()
        UIZoom.shared.zoomIn()  // 1.2
        defer { UIZoom.shared.reset() }
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 480, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Measure().uiZoomed())
        window.setContentSize(CGSize(width: 480, height: 360))
        window.orderFront(nil)
        defer { window.close() }
        spin()

        #expect(abs(Self.laidOut.width - 400) < 1)
        #expect(abs(Self.laidOut.height - 300) < 1)
    }
}
