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

    @State private var analysis: ImageAnalysis?

    var body: some View {
        ZStack {
            if let analysis {
                AnalysisOverlay(analysis: analysis)
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

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView()
        view.preferredInteractionTypes = [.textSelection, .dataDetectors]
        view.analysis = analysis
        return view
    }

    func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
        view.analysis = analysis
    }
}
