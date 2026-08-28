import AVFoundation
import SwiftUI
import VisionKit

/// iOS-style Live Text on the PAUSED frame: capture the exact playhead
/// frame at full resolution, run the system analyzer, and lay the
/// system's selection overlay over the video surface — selection, drag,
/// ⌘C and data detectors all come from VisionKit, the same machinery
/// QuickTime Player uses. The caller mounts this only while paused, so
/// resume/seek/item-switch tear it down by construction.
struct PausedFrameTextOverlay: View {
    let fileURL: URL?
    let seconds: Double
    /// A plain click on EMPTY (non-text) area, with no active selection
    /// — the caller resumes playback (#93). Text clicks and drags stay
    /// the selection's.
    var onEmptyClick: () -> Void = {}

    @State private var analysis: ImageAnalysis?

    var body: some View {
        ZStack {
            if let analysis {
                AnalysisOverlay(analysis: analysis, onEmptyClick: onEmptyClick)
            }
        }
        // No spinner — QuickTime's pattern: the frame just becomes
        // selectable when analysis lands.
        .allowsHitTesting(analysis != nil)
        .task(id: key) {
            analysis = nil
            guard let fileURL, ImageAnalyzer.isSupported else { return }
            analysis = await Self.analyze(url: fileURL, seconds: seconds).analysis
        }
    }

    /// Re-analyze on real position changes only — scrub jitter while
    /// paused buckets to a tenth of a second.
    private var key: String {
        "\(fileURL?.path ?? "-")@\((seconds * 10).rounded())"
    }

    /// The CI toolchain's SDK predates ImageAnalysis's Sendable
    /// annotation, and awaiting the nonisolated framework call from the
    /// main actor is itself the crossing it rejects. The analysis is
    /// immutable once produced, so ferrying it across in an @unchecked
    /// box is safe — and the entire pipeline stays in one nonisolated
    /// context, where the call is legal on both toolchains.
    private struct AnalysisBox: @unchecked Sendable {
        let analysis: ImageAnalysis?
    }

    private nonisolated static func analyze(url: URL, seconds: Double) async -> AnalysisBox {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time).image else {
            return AnalysisBox(analysis: nil)
        }
        let analyzer = ImageAnalyzer()
        let result = try? await analyzer.analyze(
            frame, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
        return AnalysisBox(analysis: result)
    }
}

/// The system overlay view. Its bounds must exactly match the rendered
/// video rect — the caller overlays it on the fitted surface frame, so
/// full-bounds contents are correct.
private struct AnalysisOverlay: NSViewRepresentable {
    let analysis: ImageAnalysis
    let onEmptyClick: () -> Void

    func makeNSView(context: Context) -> ClickMonitorView {
        let view = ClickMonitorView()
        view.overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        view.overlay.analysis = analysis
        view.onEmptyClick = onEmptyClick
        return view
    }

    func updateNSView(_ view: ClickMonitorView, context: Context) {
        view.overlay.analysis = analysis
        view.onEmptyClick = onEmptyClick
    }
}

/// The #93 arbitration. ImageAnalysisOverlayView is final and consumes
/// its own mouse events, so a wrapper OBSERVES them through a local
/// event monitor instead — the overlay's behavior (drags, text clicks,
/// selection clearing, even drag-to-select starting from empty space)
/// stays completely intact, and the wrapper reports the one case that
/// means "resume": a clean click (no drag) on a point with no
/// recognized text, made while no selection was active. The click that
/// clears a selection deliberately costs its own click.
final class ClickMonitorView: NSView {
    let overlay = ImageAnalysisOverlayView()
    var onEmptyClick: (() -> Void)?

    private var monitor: Any?
    private var downInfo: (point: NSPoint, ownedByOverlay: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        overlay.frame = bounds
    }

    // The monitor's lifetime is the time in a window — SwiftUI removes
    // the view on unmount (resume/seek/item switch), which tears the
    // monitor down here rather than in a deinit that couldn't touch
    // main-actor API.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    private func observe(_ event: NSEvent) {
        guard event.window === window else { return }
        let local = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(local) else {
                downInfo = nil
                return
            }
            let overlayPoint = overlay.convert(event.locationInWindow, from: nil)
            let owned = overlay.hasActiveTextSelection
                || overlay.hasInteractiveItem(at: overlayPoint)
            downInfo = (local, owned)
        case .leftMouseUp:
            defer { downInfo = nil }
            guard let down = downInfo, bounds.contains(local),
                  hypot(local.x - down.point.x, local.y - down.point.y) < 3,
                  !down.ownedByOverlay
            else { return }
            onEmptyClick?()
        default:
            break
        }
    }
}
