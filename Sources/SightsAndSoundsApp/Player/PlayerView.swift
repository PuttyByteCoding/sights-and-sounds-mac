import AVFoundation
import AVKit
import SwiftUI
import SightsAndSoundsKit

/// The playback window: custom transport (system controls can't host
/// scrub previews), the ported keyboard map, waveform timelines for
/// audio, and resume/watch-state recording.
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: PlayerRequest

    @State private var model: PlayerModel?
    @State private var openError: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let model {
                PlayerContent()
                    .environment(model)
                    .navigationTitle(model.title)
            } else if let openError {
                ContentUnavailableView(
                    "Cannot Play", systemImage: "play.slash",
                    description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handle(press) ? .handled : .ignored
        }
        .task {
            guard model == nil else { return }
            do {
                model = PlayerModel(
                    request: request,
                    library: try app.library(for: request.libraryID),
                    appDatabase: app.appDatabase)
                focused = true
            } catch {
                openError = "\(error)"
            }
        }
        .onDisappear { model?.shutdown() }
    }

    private func handle(_ press: KeyPress) -> Bool {
        guard let model else { return false }
        switch press.key {
        case .leftArrow: model.goPrevious(); return true
        case .rightArrow: model.goNext(); return true
        case .escape: dismiss(); return true
        default:
            guard let character = press.characters.first else { return false }
            return model.handle(
                character: character,
                shift: press.modifiers.contains(.shift),
                numpad: press.modifiers.contains(.numericPad))
        }
    }
}

private struct PlayerContent: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let error = model.loadError {
                    ContentUnavailableView(
                        "Cannot Play", systemImage: "play.slash",
                        description: Text(error))
                } else if model.isAudio {
                    Image(systemName: "waveform")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                } else {
                    PlayerSurface(player: model.player)
                }
            }
            TransportBar()
                .padding(10)
                .background(.bar)
        }
    }
}

/// AVPlayerLayer host — the raw video surface with no system chrome.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}

private struct TransportBar: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            ScrubberView()
            HStack(spacing: 14) {
                Button {
                    model.goPrevious()
                } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous item (←)")
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .help("Play/Pause (Space, 5)")
                Button {
                    model.goNext()
                } label: { Image(systemName: "forward.end.fill") }
                    .help("Next item (→)")

                Text(timeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if let item = model.item {
                    FlagButtons(item: item)
                }

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(String(format: "%g×", rate)) {
                            model.playbackRate = Float(rate)
                        }
                    }
                } label: {
                    Text(String(format: "%g×", model.playbackRate))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .frame(width: 64)
                .help("Playback speed")
            }
            .buttonStyle(.plain)
        }
    }

    private var timeText: String {
        format(model.currentSeconds) + " / " + format(model.durationSeconds)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The keyboard map's four flags, mirrored as toolbar toggles.
private struct FlagButtons: View {
    @Environment(PlayerModel.self) private var model
    let item: MediaItem

    var body: some View {
        HStack(spacing: 10) {
            flag(.favorite, on: item.isFavorite, "star", "Favorite (F)")
            flag(.needsReview, on: item.needsReview, "eye.trianglebadge.exclamationmark", "Needs review (R)")
            flag(.playbackIssue, on: item.playbackIssue, "play.slash", "Playback issue (W)")
            flag(.markedForDeletion, on: item.markedForDeletion, "trash", "Marked for deletion (D)")
        }
    }

    private func flag(_ flag: PlayerToggleFlag, on: Bool, _ symbol: String, _ help: String) -> some View {
        Button {
            model.perform(action(for: flag))
        } label: {
            Image(systemName: on ? symbol + ".fill" : symbol)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .help(help)
    }

    private func action(for flag: PlayerToggleFlag) -> PlayerAction {
        switch flag {
        case .favorite: .toggleFavorite
        case .needsReview: .toggleNeedsReview
        case .markedForDeletion: .toggleMarkedForDeletion
        case .playbackIssue: .togglePlaybackIssue
        }
    }
}

/// The timeline: waveform-backed for audio, hover previews for video,
/// click/drag to seek, clip range shaded.
private struct ScrubberView: View {
    @Environment(PlayerModel.self) private var model

    @State private var peaks: [Float]?
    @State private var hoverFraction: Double?
    @State private var previewImage: NSImage?
    @State private var previewBucket: Int = -1

    private let height: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                track(width: width)
                if let hoverFraction {
                    hoverOverlay(fraction: hoverFraction, width: width)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double((value.location.x / width).clamped01)
                        model.seek(to: fraction * model.durationSeconds)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let fraction = Double((point.x / width).clamped01)
                    hoverFraction = fraction
                    requestPreview(at: fraction * model.durationSeconds)
                case .ended:
                    hoverFraction = nil
                }
            }
        }
        .frame(height: height)
        .task(id: model.item?.id) {
            peaks = nil
            previewImage = nil
            previewBucket = -1
            guard model.isAudio, let item = model.item else { return }
            peaks = await WaveformProvider.shared.peaks(
                itemID: item.id, libraryID: model.libraryID, fileURL: model.fileURL)
        }
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        // CGFloat throughout — mixed Double/CGFloat arithmetic is ambiguous
        // to the CI toolchain (Xcode 16).
        let progress: CGFloat = model.durationSeconds > 0
            ? CGFloat((model.currentSeconds / model.durationSeconds).clamped01) : 0
        Canvas { context, size in
            // Base track / waveform.
            if let peaks, !peaks.isEmpty {
                let barWidth = size.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let barHeight = max(1, CGFloat(peak) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth,
                        y: (size.height - barHeight) / 2,
                        width: max(barWidth - 0.5, 0.5),
                        height: barHeight)
                    let played = CGFloat(index) / CGFloat(peaks.count) <= progress
                    context.fill(
                        Path(rect),
                        with: .color(played ? .accentColor : .secondary.opacity(0.45)))
                }
            } else {
                let track = CGRect(x: 0, y: size.height / 2 - 2, width: size.width, height: 4)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.secondary.opacity(0.3)))
                let played = CGRect(x: 0, y: size.height / 2 - 2, width: size.width * progress, height: 4)
                context.fill(Path(roundedRect: played, cornerRadius: 2), with: .color(.accentColor))
            }

            // Clip range shading.
            if let item = model.item, model.durationSeconds > 0,
               let start = item.clipStartSeconds {
                let end = item.clipEndSeconds ?? model.durationSeconds
                let x0 = size.width * CGFloat((start / model.durationSeconds).clamped01)
                let x1 = size.width * CGFloat((end / model.durationSeconds).clamped01)
                context.fill(
                    Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                    with: .color(.accentColor.opacity(0.12)))
            }

            // Playhead.
            let x = size.width * progress
            context.fill(
                Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
                with: .color(.primary))
        }
    }

    @ViewBuilder
    private func hoverOverlay(fraction: Double, width: CGFloat) -> some View {
        let seconds = fraction * model.durationSeconds
        VStack(spacing: 2) {
            if let previewImage, !model.isAudio {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(radius: 3)
            }
            Text(TransportBarTime.format(seconds))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
        }
        .offset(x: overlayX(fraction: fraction, width: width), y: -78)
        .allowsHitTesting(false)
    }

    /// Explicit CGFloat arithmetic — mixed Double/CGFloat expressions are
    /// ambiguous to the CI toolchain (Xcode 16).
    private func overlayX(fraction: Double, width: CGFloat) -> CGFloat {
        let x = CGFloat(fraction) * width - 80
        let upper = max(width - 160, 0)
        return x.clamped(to: 0...upper)
    }

    private func requestPreview(at seconds: Double) {
        guard !model.isAudio, let item = model.item, let fileURL = model.fileURL,
              seconds.isFinite
        else { return }
        let bucket = Int(seconds / ScrubPreviewProvider.bucketSeconds)
        guard bucket != previewBucket else { return }
        previewBucket = bucket
        Task {
            let data = await ScrubPreviewProvider.shared.preview(
                itemID: item.id, fileURL: fileURL, atSeconds: seconds)
            if previewBucket == bucket {
                previewImage = data.flatMap(NSImage.init(data:))
            }
        }
    }
}

enum TransportBarTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

extension CGFloat {
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) }
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
