import SwiftUI
import SightsAndSoundsKit

/// The app-wide zoom, live. `AppSettingsStore` is read-at-use-time, so
/// this observable wrapper is what makes ⌘= take effect on screen
/// immediately; the store is still the persistence, so the zoom
/// survives a relaunch.
@Observable
@MainActor
final class UIZoom {
    static let shared = UIZoom()

    private(set) var scale: Double = AppSettingsStore.shared.current.uiScale

    static let minScale = 0.7
    static let maxScale = 1.8
    private static let step = 0.1

    func zoomIn() { set(scale + Self.step) }
    func zoomOut() { set(scale - Self.step) }
    func reset() { set(1.0) }

    private func set(_ raw: Double) {
        // Snap to the step grid so repeated in/out lands back on exactly
        // 1.0 instead of 0.9999….
        let snapped = (raw / Self.step).rounded() * Self.step
        scale = min(Self.maxScale, max(Self.minScale, snapped))
        AppSettingsStore.shared.update { $0.uiScale = scale }
    }
}

/// Zoom one window's content. Layout happens at the ENLARGED logical
/// size and the result is scaled — so text reflows and nothing is
/// cropped, unlike a bare scaleEffect. At 1.0 this is exactly the
/// unmodified view.
///
/// One structure at every scale. It used to return `content` at 1.0
/// and a GeometryReader otherwise; crossing 1.0 swapped branches, which
/// gave the content a new identity and threw away every @State under
/// it — a library window's model, filter, selection and playing video.
struct UIZoomModifier: ViewModifier {
    func body(content: Content) -> some View {
        let scale = UIZoom.shared.scale
        ZoomLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// Lays its one child out at `size / scale` and reports `child × scale`
/// upward, so the scaled drawing fills exactly the space it was given.
/// A pass-through at 1.0 — unlike a GeometryReader, it never grows to
/// fill space the content would not have taken.
private struct ZoomLayout: Layout {
    let scale: Double

    private func shrunk(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: proposal.width.map { $0 / scale },
            height: proposal.height.map { $0 / scale })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(shrunk(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
    }
}

extension View {
    func uiZoomed() -> some View { modifier(UIZoomModifier()) }
}
