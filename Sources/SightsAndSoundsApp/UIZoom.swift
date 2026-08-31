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
struct UIZoomModifier: ViewModifier {
    func body(content: Content) -> some View {
        let scale = UIZoom.shared.scale
        if scale == 1.0 {
            content
        } else {
            GeometryReader { geometry in
                content
                    .frame(
                        width: geometry.size.width / scale,
                        height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
            }
        }
    }
}

extension View {
    func uiZoomed() -> some View { modifier(UIZoomModifier()) }
}
