import AVFoundation
import AVKit
import SwiftUI
import SightsAndSoundsKit

/// The playback surface, embedded in the library window it was opened
/// from: custom transport (system controls can't host scrub previews),
/// the ported keyboard map, waveform timelines for audio, and
/// resume/watch-state recording. `onClose` hands the window back to
/// the browse grid (Back button, or Esc).
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    let request: PlayerRequest
    let onClose: () -> Void

    @State private var model: PlayerModel?
    @State private var openError: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let model {
                PlayerContent(refocus: { focused = true })
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { onClose() }
                    .help("Back to the library (Esc)")
            }
        }
        // Low mins: the video's 150 pt floor is enforced by the panel
        // clamps (#85), not by a wide hard minimum — a big minimum here
        // would stop the sidebar's drag long before the floor.
        .frame(minWidth: 320, minHeight: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // With the sidebar alive beside the player, any click out there
        // takes keyboard focus with it — and the key map dies silently.
        // Closing the tag panel is the moment tagging hands control back.
        .onChange(of: model?.showTagPanel ?? false) { _, showing in
            if !showing { focused = true }
        }
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

    /// Option+digit reaches us as the layout's option glyph on most
    /// keyboards; map the US row back to digits (and accept plain digits
    /// for layouts that pass them through).
    private static let optionDigitGlyphs: [Character: Int] = [
        "¡": 1, "™": 2, "£": 3, "¢": 4, "∞": 5, "§": 6, "¶": 7, "•": 8, "ª": 9,
    ]

    private func handle(_ press: KeyPress) -> Bool {
        // Esc leaves the player even when the item failed to open.
        if press.key == .escape {
            if let model, model.showTagPanel {
                model.showTagPanel = false
            } else {
                onClose()
            }
            return true
        }
        guard let model else { return false }
        switch press.key {
        case .leftArrow: model.goPrevious(); return true
        case .rightArrow: model.goNext(); return true
        default: break
        }

        guard let character = press.characters.first else { return false }

        // Alt+1…9: toggle the checkbox category's Nth tag.
        if press.modifiers.contains(.option) {
            let digit = Self.optionDigitGlyphs[character]
                ?? character.wholeNumberValue.flatMap { (1...9).contains($0) ? $0 : nil }
            if let digit { return model.toggleCheckboxTag(at: digit) }
            return false
        }

        // Ctrl+{ / Ctrl+}: clip in/out points (the old map's clip keys).
        if press.modifiers.contains(.control) {
            if character == "{" { model.setClipIn(); return true }
            if character == "}" { model.setClipOut(); return true }
        }
        // Plain { }: hide-block open/close taps, ported.
        if character == "{" { model.blockTap(open: true); return true }
        if character == "}" { model.blockTap(open: false); return true }

        // T: tag panel (fixed key, matching the old map).
        if press.modifiers.isDisjoint(with: [.shift, .command, .control]),
           character.lowercased() == "t" {
            model.showTagPanel.toggle()
            return true
        }

        // F-key tag bindings fire regardless of shift (function keys never
        // type text); letter bindings only without modifiers.
        if let fMatch = press.key.character.unicodeScalars.first,
           (0xF704...0xF70C).contains(fMatch.value) {  // NSF1FunctionKey…NSF9
            let index = Int(fMatch.value - 0xF704) + 1
            if model.handleBoundKey("F\(index)") { return true }
        }
        if press.modifiers.isDisjoint(with: [.shift, .command, .control]),
           character.isLetter, model.handleBoundKey(String(character)) {
            return true
        }

        // M/L: mute and loop toggles — after the binding check, so a
        // tag bound to either keeps winning.
        if press.modifiers.isDisjoint(with: [.shift, .command, .control]) {
            if character.lowercased() == "m" {
                model.toggleMute()
                return true
            }
            if character.lowercased() == "l" {
                model.toggleLoop()
                return true
            }
        }

        return model.handle(
            character: character,
            shift: press.modifiers.contains(.shift),
            numpad: press.modifiers.contains(.numericPad))
    }
}

private struct PlayerContent: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    /// Re-claims the player's keyboard focus. Wired to clicks on the
    /// video/transport area only — never the tag panel, whose text
    /// fields need to keep the focus they take.
    let refocus: () -> Void
    @State private var showBindingsEditor = false
    @State private var showTextPanel = false

    /// Panel sizes: draggable, clamped so the video always keeps a
    /// floor, persisted so they survive item switches (the .id(request)
    /// rebuild) and launches.
    @State private var layout = AppSettingsStore.shared.current.playerLayout
    @State private var dragBase: CGFloat?

    // ONE rule limits every panel: expansion stops only when the video
    // area would drop below its 150×150 floor (#85). Ceilings are
    // DYNAMIC — measured content size minus the other occupants — and
    // stored sizes are clamped at APPLY time, so a layout saved on a
    // big window squeezes on a small one and re-expands when room
    // returns, without rewriting what the user chose.
    private static let videoFloor: CGFloat = 150
    private static let handleThickness: CGFloat = 5  // 1 pt line + 2×2 padding
    @State private var contentSize: CGSize = .zero
    @State private var chromeHeight: CGFloat = 0  // info bar + transport

    private var tagPanelCeiling: CGFloat {
        max(0, contentSize.width - Self.videoFloor - Self.handleThickness
            - (showTextPanel ? 300 : 0))
    }

    private var queueCeiling: CGFloat {
        max(0, contentSize.height - Self.videoFloor - chromeHeight - Self.handleThickness)
    }

    private var effectiveTagPanelWidth: CGFloat {
        guard contentSize.width > 0 else { return CGFloat(layout.tagPanelWidth) }
        return min(CGFloat(layout.tagPanelWidth), tagPanelCeiling)
    }

    private var effectiveQueueHeight: CGFloat {
        guard contentSize.height > 0, chromeHeight > 0 else {
            return CGFloat(layout.queueHeight)
        }
        return min(CGFloat(layout.queueHeight), queueCeiling)
    }

    private func dragTagPanel(_ translation: CGFloat) {
        let base = dragBase ?? effectiveTagPanelWidth
        dragBase = base
        layout.tagPanelWidth = Double(
            min(max(220, base - translation), max(220, tagPanelCeiling)))
    }

    /// The smallest queue that shows a whole cell: minimum thumbnail
    /// (24) + the metadata reserve for the enabled fields + chrome.
    private var queueMinHeight: CGFloat {
        QueueCell.metadataHeight(for: AppSettingsStore.shared.current.grid) + 42
    }

    private func dragQueue(_ translation: CGFloat) {
        let base = dragBase ?? effectiveQueueHeight
        dragBase = base
        let floor = queueMinHeight
        layout.queueHeight = Double(
            min(max(floor, base - translation), max(floor, queueCeiling)))
    }

    private func endPanelDrag() {
        dragBase = nil
        AppSettingsStore.shared.update { $0.playerLayout = layout }
    }

    private var queueShown: Binding<Bool> {
        Binding(
            get: { layout.showsQueue },
            set: { shown in
                layout.showsQueue = shown
                AppSettingsStore.shared.update { $0.playerLayout = layout }
            })
    }

    /// The exact rendered size: aspect-fit into the available area, but
    /// upscaling stops at 2× the video's native PIXEL size (in points,
    /// so a Retina backing scale doesn't quietly double it again). An
    /// exact frame — not a max — because the surface must hug the
    /// top-left corner, and AVPlayerLayer centers inside its own bounds.
    /// Nil (dimensions unknown) means fill the area as before.
    private func fittedVideoSize(in available: CGSize) -> CGSize? {
        guard let item = model.item,
              let width = item.width, let height = item.height,
              width > 0, height > 0, available.width > 0, available.height > 0
        else { return nil }
        let capPointsPerPixel = 2 / max(displayScale, 1)
        let scale = min(
            available.width / CGFloat(width),
            available.height / CGFloat(height),
            capPointsPerPixel)
        return CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Video hugs the top-left; black fills right and below.
                // Placeholder and error states stay centered.
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let error = model.loadError {
                        ContentUnavailableView(
                            "Cannot Play", systemImage: "play.slash",
                            description: Text(error))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.isAudio {
                        Image(systemName: "waveform")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geometry in
                            let fitted = fittedVideoSize(in: geometry.size)
                            PlayerSurface(player: model.player)
                                .frame(width: fitted?.width, height: fitted?.height)
                                // Live Text rides the PAUSED frame only —
                                // resume, seek or item switch tears it
                                // down with the condition. The overlay
                                // shares the surface's exact fitted rect.
                                .overlay {
                                    if !model.isPlaying, !model.isAudio {
                                        PausedFrameTextOverlay(
                                            fileURL: model.fileURL,
                                            seconds: model.currentSeconds)
                                    }
                                }
                        }
                    }
                }
                VStack(spacing: 0) {
                    InfoBar()
                    TransportBar(queueShown: queueShown)
                        .padding(10)
                        .background(.bar)
                }
                // The fixed strips' height comes out of the vertical
                // budget before the video floor is measured.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    chromeHeight = $0
                }
                if layout.showsQueue, !model.playlist.isEmpty {
                    HorizontalResizeHandle(
                        onDrag: { dragQueue($0) }, onEnd: { endPanelDrag() })
                    QueuePanel(height: effectiveQueueHeight)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { refocus() })
            if model.showTagPanel {
                VerticalResizeHandle(
                    onDrag: { dragTagPanel($0) }, onEnd: { endPanelDrag() })
                TagPanelView(width: effectiveTagPanelWidth)
            }
            if showTextPanel {
                OcrLinesPanel()
            }
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
        .toolbar {
            Button("Tags", systemImage: "tag") {
                model.showTagPanel.toggle()
            }
            .help("Tag panel (T)")
            Button("On-Screen Text", systemImage: "text.viewfinder") {
                showTextPanel.toggle()
            }
            .help("Scanned on-screen text — timestamped, copyable, click to seek. Pause the video to select text on the frame itself.")
            Button("Key Bindings", systemImage: "keyboard") { showBindingsEditor = true }
                .help("Bind keys to tags")
        }
        .sheet(isPresented: $showBindingsEditor) {
            KeyBindingsEditor()
                .environment(model)
        }
    }
}

/// The info strip between the video and the transport: position in the
/// filtered listing, tag pills (right-click to edit), favorite star,
/// and Save a Copy. Which elements show is a Playback setting, read per
/// render — like every setting, changes apply without relaunch.
private struct InfoBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var editingTag: Tag?

    var body: some View {
        let settings = AppSettingsStore.shared.current.infoBar
        if settings.showsAnything, let item = model.item {
            HStack(spacing: 12) {
                if settings.showsPosition, !model.playlist.isEmpty,
                   let index = model.playlist.firstIndex(of: item.id) {
                    Text("\(index + 1) of \(model.playlist.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Position in the filtered listing this item was opened from")
                }
                if settings.showsFavorite {
                    Button {
                        model.perform(.toggleFavorite)
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isFavorite ? "Favorite — click to remove (F)" : "Mark favorite (F)")
                }
                if settings.showsTags {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.itemTags.flatMap(\.tags)) { tag in
                                Text(tag.name)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .contextMenu {
                                        Button("Edit…") { editingTag = tag }
                                    }
                            }
                        }
                    }
                }
                Spacer()
                if settings.showsDownload {
                    Button("Save a Copy…", systemImage: "square.and.arrow.down") {
                        saveCopy(of: item)
                    }
                    .disabled(model.fileURL == nil)
                    .help("Copy the media file to a location you choose")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .sheet(item: $editingTag) { tag in
                RenameTagSheet(tag: tag) { newName in
                    model.renameTag(tag.id, to: newName)
                }
            }
        }
    }

    /// "Download" in a local app: export a copy where the user says.
    /// The copy runs off the main actor — media files are large. An
    /// embedded clip resolves to its PARENT's file, so the copy is the
    /// whole parent; exporting just the range stays the clip-export job.
    private func saveCopy(of item: MediaItem) {
        guard let sourceURL = model.fileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = item.fileName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let model = model
        Task.detached(priority: .userInitiated) {
            do {
                // The panel already confirmed replacement.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                await MainActor.run { model.loadError = "Save failed: \(error)" }
            }
        }
    }
}

/// One-field rename, saving through the kit's normalized write path.
private struct RenameTagSheet: View {
    let tag: Tag
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(tag: Tag, onSave: @escaping (String) -> Void) {
        self.tag = tag
        self.onSave = onSave
        _name = State(initialValue: tag.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag").font(.headline)
            TextField("Name", text: $name)
                .onSubmit { save() }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
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
    @Binding var queueShown: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            if model.pendingClipStart != nil || model.pendingClipEnd != nil {
                ClipAuthoringBar()
            }
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
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .help(model.isMuted ? "Unmute (M)" : "Mute (M)")
                Button {
                    model.toggleLoop()
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(model.isLooping ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                }
                .help(model.isLooping ? "Looping — click to play once (L)" : "Loop (L)")
                Button {
                    queueShown.toggle()
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(queueShown ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                }
                .help(queueShown ? "Hide the play queue" : "Show the play queue")

                Text(timeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if let item = model.item {
                    FlagButtons(item: item)
                }

                if !model.hideBlocks.isEmpty || model.pendingBlockStart != nil {
                    Menu {
                        if let start = model.pendingBlockStart {
                            Text("Block open at \(TransportBarTime.format(start)) — } closes it")
                        }
                        ForEach(model.hideBlocks) { block in
                            Button(role: .destructive) {
                                model.deleteBlock(block.id)
                            } label: {
                                Text("Remove \(TransportBarTime.format(block.startSeconds)) – \(TransportBarTime.format(block.endSeconds))")
                            }
                        }
                    } label: {
                        Label("\(model.hideBlocks.count)", systemImage: "eye.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 56)
                    .help("Hide blocks: { opens at the playhead, } closes. They skip during playback; export an edited copy from the browse grid.")
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

            // Hide blocks: dim shading — these ranges skip live and the
            // removal edit cuts them.
            if model.durationSeconds > 0 {
                for block in model.hideBlocks {
                    let x0 = size.width * CGFloat((block.startSeconds / model.durationSeconds).clamped01)
                    let x1 = size.width * CGFloat((block.endSeconds / model.durationSeconds).clamped01)
                    context.fill(
                        Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                        with: .color(.red.opacity(0.18)))
                }
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


/// The in-progress clip range: shown while either point is set, saved
/// once both are (⌃{ sets in, ⌃} sets out).
private struct ClipAuthoringBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
            Text(rangeText).font(.callout.monospacedDigit())
            if model.pendingClipReady {
                TextField("Clip name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Save Clip") {
                    model.savePendingClip(named: name)
                    name = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Text("set the other point (⌃{ / ⌃})")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.cancelPendingClip() }
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private var rangeText: String {
        let start = model.pendingClipStart.map(TransportBarTime.format) ?? "—"
        let end = model.pendingClipEnd.map(TransportBarTime.format) ?? "—"
        return "\(start) → \(end)"
    }
}

/// Edge-drag handles, sidebar-style. They sit on the PANEL side of the
/// tap-to-refocus boundary so resizing never fights the focus gesture.
private struct VerticalResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() })
    }
}

private struct HorizontalResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onDrag($0.translation.height) }
                    .onEnded { _ in onEnd() })
    }
}
/// The play queue: ONE fully-visible row of grid-style cells —
/// letterboxed thumbnail on top, the grid's enabled metadata fields
/// beneath — scrolling horizontally, current item ringed and kept
/// centered. Cell math is deterministic: the metadata reserve is
/// computed from the enabled fields and the thumbnail takes the rest,
/// so nothing can clip at any divider height. The queue reflects the
/// playlist SNAPSHOT the player opened with.
private struct QueuePanel: View {
    @Environment(PlayerModel.self) private var model
    let height: CGFloat

    var body: some View {
        let grid = AppSettingsStore.shared.current.grid
        let metadataHeight = QueueCell.metadataHeight(for: grid)
        let thumbHeight = max(24, height - 18 - metadataHeight)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(model.queueItems) { item in
                        QueueCell(
                            item: item,
                            thumbHeight: thumbHeight,
                            grid: grid,
                            isCurrent: item.id == model.item?.id)
                            .id(item.id)
                            .onTapGesture { model.load(itemID: item.id) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.item?.id) { _, current in
                if let current {
                    withAnimation { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .onAppear {
                if let current = model.item?.id {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
        // Natural content height — never taller than its cells, never
        // clipping them.
        .frame(height: thumbHeight + metadataHeight + 18)
        .background(.bar)
    }
}

private struct QueueCell: View {
    @Environment(PlayerModel.self) private var model
    let item: MediaItem
    let thumbHeight: CGFloat
    let grid: GridSettings
    let isCurrent: Bool
    @State private var thumbnail: NSImage?

    /// Deterministic reserve for the text under the thumbnail; the
    /// estimates match the fonts used below. The panel divides its
    /// height into thumbnail + this, so cells always fit whole.
    static func metadataHeight(for grid: GridSettings) -> CGFloat {
        var height: CGFloat = 0
        if grid.showsFileName { height += 18 }
        if grid.showsPath { height += 14 }
        if hasMetaRow(grid) { height += 16 }
        return height == 0 ? 0 : height + 4
    }

    private static func hasMetaRow(_ grid: GridSettings) -> Bool {
        grid.showsDuration || grid.showsFileSize || grid.showsDimensions
            || grid.showsImportDate || grid.showsViewCount || grid.showsFavorite
            || grid.showsReviewed || grid.showsDeleted || grid.showsClip
    }

    private var cellWidth: CGFloat { thumbHeight * 16 / 9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Letterboxed like the grid (#68): the ENTIRE frame visible,
            // portrait pillarboxed on black.
            ZStack {
                Color.black
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .audio ? "waveform" : "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: cellWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if grid.showsFileName {
                Text(item.fileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if grid.showsPath {
                Text(item.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if Self.hasMetaRow(grid) {
                metaRow
            }
        }
        .frame(width: cellWidth)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2))
        .help(item.fileName)
        .task(id: item.id) {
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id, libraryID: model.libraryID,
                fileURL: model.queueFileURL(for: item),
                durationSeconds: item.durationSeconds)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if grid.showsDuration, let duration = item.durationSeconds {
                Text(TransportBarTime.format(duration))
            }
            if grid.showsFileSize {
                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            }
            if grid.showsDimensions, let width = item.width, let height = item.height {
                Text("\(width)×\(height)")
            }
            if grid.showsImportDate {
                Text(item.ingestDate.formatted(date: .abbreviated, time: .omitted))
            }
            if grid.showsViewCount, item.watchCount > 0 {
                Text("▶ \(item.watchCount)")
            }
            Spacer(minLength: 0)
            if grid.showsFavorite, item.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
            if grid.showsReviewed, item.needsReview {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if grid.showsDeleted, item.markedForDeletion {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            if grid.showsClip, item.isClip {
                Image(systemName: "scissors")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
