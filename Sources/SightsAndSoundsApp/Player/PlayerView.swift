import AVFoundation
import AVKit
import SwiftUI
import SightsAndSoundsKit

/// The playback surface, embedded in the library window it was opened
/// from: custom transport (system controls can't host scrub previews),
/// the ported keyboard map, waveform timelines for audio, and
/// resume/watch-state recording. `onClose` hands the window back to the
/// browse grid (Back button, or Esc from the video zone).
///
/// The player owns playback and the keys. Tagging, segments, on-screen
/// text and the queue are separate panels around it — the 4,382-line
/// lesson from the web app's player component.
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    /// The player lives in the browse window's detail column, so the
    /// listing that opened it is still right there — which is what lets
    /// the queue follow the filter instead of being a snapshot.
    @Environment(BrowseModel.self) private var browse
    let request: PlayerRequest
    let onClose: () -> Void

    @State private var model: PlayerModel?
    @State private var openError: String?
    @State private var showKeyMap = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let model {
                PlayerContent(
                    refocus: { focused = true },
                    showKeyMap: $showKeyMap)
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
        // Releasing to the video zone is the moment a panel hands the
        // keyboard back.
        .onChange(of: model?.zone ?? .video) { _, zone in
            if zone == .video { focused = true }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            handle(press) ? .handled : .ignored
        }
        .sheet(isPresented: $showKeyMap) {
            if let model {
                KeyMapSheet().environment(model)
            }
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
        // The queue follows the browse listing. Keyed on the ids so a
        // refresh returning the same items does nothing.
        .onChange(of: browse.visibleItems.map(\.id)) { _, ids in
            model?.updatePlaylist(ids)
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
        guard let model else {
            // Esc leaves the player even when the item failed to open.
            if press.key == .escape { onClose(); return true }
            return false
        }
        let style = model.keyMap

        // Esc unwinds EXACTLY ONE layer, in this order: an open mark, the
        // focus zone, then the player. Never two — clearing a selection
        // and leaving in one press is how you lose work you could see.
        if press.key == .escape {
            if model.pendingSegmentStart != nil || model.pendingBlockStart != nil {
                model.cancelSegmentMark()
                model.pendingBlockStart = nil
                return true
            }
            if model.zone != .video {
                model.zone = .video
                focused = true
                return true
            }
            onClose()
            return true
        }

        // Tab walks video → tags → segments → queue, skipping whatever is
        // collapsed. The footer names where it landed.
        if press.key == .tab {
            model.moveZone(
                reverse: press.modifiers.contains(.shift), available: model.availableZones)
            focused = true
            return true
        }

        // While a text input owns the keyboard, the single-key map is
        // suspended — "d" spells a tag name, it doesn't delete (#105).
        // Every SwiftUI text field types through an AppKit field editor
        // (an NSTextView), so checking the first responder covers them
        // all without threading focus state through each field.
        //
        // Two exceptions, both deliberate. F-keys never insert text. And
        // the NUMPAD seeks: rewinding four seconds mid-word is the whole
        // reason the numpad is in the map, and the digits are separable
        // from the top row that is spelling the tag. Arrow keys carry the
        // same numeric-pad flag and belong to the text cursor, so the
        // exception is limited to characters that actually type digits.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            if let scalar = press.key.character.unicodeScalars.first,
               (0xF704...0xF70C).contains(scalar.value) {
                let index = Int(scalar.value - 0xF704) + 1
                return model.handleBoundKey("F\(index)")
            }
            if press.modifiers.contains(.numericPad), let character = press.characters.first,
               character.isNumber || character == "-" {
                return model.handle(character: character, shift: false, numpad: true)
            }
            return false
        }

        // Walking the playlist: bare arrows on the Mac map, shifted on
        // the web map. In the segments zone the arrows pick rows instead
        // — the zone is what the keys are pointed at.
        let shift = press.modifiers.contains(.shift)
        if press.key == .leftArrow || press.key == .rightArrow || press.key == .upArrow
            || press.key == .downArrow {
            if model.zone == .segments,
               press.key == .upArrow || press.key == .downArrow {
                model.stepSegmentSelection(press.key == .downArrow ? 1 : -1)
                return true
            }
            guard press.key == .leftArrow || press.key == .rightArrow else { return false }
            let arrow: PlayerKeyMap.Arrow = press.key == .leftArrow ? .left : .right
            guard let step = PlayerKeyMap.playlistStep(arrow: arrow, shift: shift, style: style)
            else { return false }
            step < 0 ? model.goPrevious() : model.goNext()
            return true
        }

        if press.key == .return, model.zone == .segments,
           let row = model.selectedSegment {
            model.playSegment(row)
            return true
        }

        guard let character = press.characters.first else { return false }

        // Alt+1…9: toggle the checkbox category's Nth tag.
        if press.modifiers.contains(.option) {
            let digit = Self.optionDigitGlyphs[character]
                ?? character.wholeNumberValue.flatMap { (1...9).contains($0) ? $0 : nil }
            if let digit { return model.toggleCheckboxTag(at: digit) }
            return false
        }

        // `?` is the keyboard map — chooser and permanent cheat sheet.
        if character == "?" {
            showKeyMap = true
            return true
        }

        // Segment marks. `C` closes as a clip rather than a song, and is
        // consulted only while a mark is open — with nothing marked it
        // belongs to whatever binding claims it.
        let control = press.modifiers.contains(.control)
        if let mark = PlayerKeyMap.segmentMark(
            character: character, control: control, style: style) {
            switch mark {
            case .open:
                model.openSegmentMark()
                return true
            case .close:
                model.closeSegmentMark(as: .song)
                return true
            case .closeAsClip:
                if model.pendingSegmentStart != nil {
                    model.closeSegmentMark(as: .clip)
                    return true
                }
            }
        }

        // Plain { }: hide-block open/close taps, ported. A hide block is
        // an instruction to an edit, not a segment record, so it keeps
        // its own keys in both maps.
        if !control, character == "{" { model.blockTap(open: true); return true }
        if !control, character == "}" { model.blockTap(open: false); return true }

        // T: tag panel (fixed key, matching the old map).
        if press.modifiers.isDisjoint(with: [.shift, .command, .control]),
           character.lowercased() == "t" {
            model.togglePanel(.tags)
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

        // Triage: the fixed flag keys mark and ADVANCE, but only inside
        // the mode, and only on the map that claims them. Outside it they
        // fall through to the plain toggles below and stay put.
        if model.triageMode, press.modifiers.isDisjoint(with: [.shift, .command, .control]),
           let action = PlayerKeyMap.triageAction(character: character, style: style) {
            return model.triageMark(action)
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
            shift: shift,
            numpad: press.modifiers.contains(.numericPad))
    }
}

// MARK: - Layout

private struct PlayerContent: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    /// Re-claims the player's keyboard focus. Wired to clicks on the
    /// video/transport area only — never the tag panel, whose text
    /// fields need to keep the focus they take.
    let refocus: () -> Void
    @Binding var showKeyMap: Bool
    @State private var showBindingsEditor = false

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
    @State private var chromeHeight: CGFloat = 0  // transport block

    /// The right side is ONE rail now, so there is one width to resolve
    /// against the video floor rather than two panels scaling jointly.
    private var effectiveRailWidth: CGFloat {
        guard model.showsRail else { return 0 }
        let stored = CGFloat(layout.railWidth)
        guard contentSize.width > 0 else { return stored }
        let ceiling = max(220, contentSize.width - Self.videoFloor - Self.handleThickness)
        return min(stored, ceiling)
    }

    private var verticalCeiling: CGFloat {
        max(0, contentSize.height - Self.videoFloor - chromeHeight)
    }

    /// Drawers share what is left under the video floor; whichever one is
    /// being dragged is clamped against the other's current height.
    private func drawerCeiling(excluding other: CGFloat) -> CGFloat {
        max(0, verticalCeiling - other - Self.handleThickness * 2)
    }

    private var effectiveTextHeight: CGFloat {
        guard model.panels.text else { return 0 }
        guard contentSize.height > 0, chromeHeight > 0 else {
            return CGFloat(layout.textDrawerHeight)
        }
        return min(CGFloat(layout.textDrawerHeight), drawerCeiling(excluding: rawQueueHeight))
    }

    private var rawQueueHeight: CGFloat {
        model.panels.queue && !model.playlist.isEmpty ? CGFloat(layout.queueHeight) : 0
    }

    private var effectiveQueueHeight: CGFloat {
        guard rawQueueHeight > 0 else { return 0 }
        guard contentSize.height > 0, chromeHeight > 0 else { return rawQueueHeight }
        return min(rawQueueHeight, drawerCeiling(excluding: effectiveTextHeight))
    }

    private func dragRail(_ translation: CGFloat) {
        let base = dragBase ?? effectiveRailWidth
        dragBase = base
        let ceiling = max(220, contentSize.width - Self.videoFloor - Self.handleThickness)
        layout.railWidth = Double(min(max(220, base - translation), ceiling).rounded())
    }

    private func dragText(_ translation: CGFloat) {
        let base = dragBase ?? effectiveTextHeight
        dragBase = base
        let ceiling = max(80, drawerCeiling(excluding: effectiveQueueHeight))
        layout.textDrawerHeight = Double(min(max(80, base - translation), ceiling).rounded())
    }

    /// The smallest queue that shows a whole cell: minimum thumbnail
    /// (24) + the metadata reserve for the enabled values + chrome.
    private var queueMinHeight: CGFloat {
        QueueCell.metadataHeight(for: GridDisplaySettings.shared.grid) + 42
    }

    private func dragQueue(_ translation: CGFloat) {
        let base = dragBase ?? effectiveQueueHeight
        dragBase = base
        let floor = queueMinHeight
        let ceiling = max(floor, drawerCeiling(excluding: effectiveTextHeight))
        layout.queueHeight = Double(min(max(floor, base - translation), ceiling).rounded())
    }

    private func endPanelDrag() {
        dragBase = nil
        AppSettingsStore.shared.update { $0.playerLayout = layout }
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftColumn
                if model.showsRail {
                    VerticalResizeHandle(
                        onDrag: { dragRail($0) }, onEnd: { endPanelDrag() })
                    SegmentsAndTagsRail(width: effectiveRailWidth)
                }
            }
            FocusFooter()
        }
        .background(Theme.Surface.content)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
        .toolbar { toolbarItems }
        .sheet(isPresented: $showBindingsEditor) {
            KeyBindingsEditor()
                .environment(model)
        }
        .onChange(of: model.panels) { _, panels in
            layout.panels = panels
            AppSettingsStore.shared.update { $0.playerLayout = layout }
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            videoStage
                .simultaneousGesture(TapGesture().onEnded { refocus() })
            TransportBlock()
                // The fixed strip's height comes out of the vertical
                // budget before the video floor is measured.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    chromeHeight = $0
                }
            if model.panels.text {
                HorizontalResizeHandle(
                    onDrag: { dragText($0) }, onEnd: { endPanelDrag() })
                OcrLinesPanel(height: effectiveTextHeight)
            }
            if model.panels.queue, !model.playlist.isEmpty {
                HorizontalResizeHandle(
                    onDrag: { dragQueue($0) }, onEnd: { endPanelDrag() })
                QueuePanel(height: effectiveQueueHeight)
            }
        }
    }

    private var videoStage: some View {
        // Video hugs the top-left; the stage fills right and below.
        // Placeholder and error states stay centered.
        ZStack(alignment: .topLeading) {
            Theme.Surface.stage
            if let error = model.loadError {
                ContentUnavailableView(
                    "Cannot Play", systemImage: "play.slash",
                    description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isAudio {
                Image(systemName: "waveform")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.Text.disabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let fitted = fittedVideoSize(in: geometry.size)
                    PlayerSurface(player: model.player)
                        .frame(width: fitted?.width, height: fitted?.height)
                        // Live Text rides the PAUSED frame only — resume,
                        // seek or item switch tears it down with the
                        // condition. The overlay shares the surface's
                        // exact fitted rect, so it follows the anchor for
                        // free. A plain click on EMPTY (non-text) area
                        // resumes; text clicks and drags belong to the
                        // selection (#93).
                        .overlay {
                            if !model.isPlaying, !model.isAudio {
                                PausedFrameTextOverlay(
                                    fileURL: model.fileURL,
                                    seconds: model.currentSeconds,
                                    onEmptyClick: { model.play() })
                            }
                        }
                        // The anchor setting (#92): placement only — the
                        // fitted-size math is untouched.
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                            alignment: AppSettingsStore.shared.current.videoAnchor.alignment)
                }
            }
        }
        // Click the video to pause/resume (#93) — same action as Space.
        // While the Live Text overlay is up it consumes its own clicks
        // (text/selection); only empty-area clicks reach back here.
        .onTapGesture {
            model.zone = .video
            model.togglePlayPause()
        }
        .zoneRing(.video)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            // The flags live here, once. They used to be mirrored in the
            // info strip under the video as well; one name, one place.
            if let item = model.item {
                FlagButtons(item: item)
            }
        }
        ToolbarItem {
            TriageButton()
        }
        ToolbarItem {
            PanelToggles()
        }
        ToolbarItem {
            Menu {
                Button("Keyboard Map…", systemImage: "questionmark.square") {
                    showKeyMap = true
                }
                Button("Key Bindings…", systemImage: "keyboard") { showBindingsEditor = true }
                Divider()
                if AppSettingsStore.shared.current.infoBar.showsDownload {
                    Button("Save a Copy…", systemImage: "square.and.arrow.down") {
                        saveCopy()
                    }
                    .disabled(model.fileURL == nil)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Keyboard map, key bindings, save a copy")
        }
    }

    /// "Download" in a local app: export a copy where the user says.
    /// The copy runs off the main actor — media files are large. An
    /// embedded clip resolves to its PARENT's file, so the copy is the
    /// whole parent; exporting just the range stays the clip-export job.
    private func saveCopy() {
        guard let item = model.item, let sourceURL = model.fileURL else { return }
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

/// The 1 pt amber inset ring on whichever zone holds focus. "Where do my
/// keys go" is answerable without pressing anything.
private struct ZoneRing: ViewModifier {
    @Environment(PlayerModel.self) private var model
    let zone: PlayerZone

    func body(content: Content) -> some View {
        content.overlay {
            if model.zone == zone {
                Rectangle()
                    .strokeBorder(Theme.Accent.amber, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    fileprivate func zoneRing(_ zone: PlayerZone) -> some View {
        modifier(ZoneRing(zone: zone))
    }
}

// MARK: - Transport

/// The scrubber with its segment lanes, then one row of controls. The
/// hide-block menu that used to sit here is gone: the segments rail is
/// the one place ranges are listed.
private struct TransportBlock: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let start = model.pendingSegmentStart {
                MarkingIndicator(start: start)
            }
            if model.pendingClipStart != nil || model.pendingClipEnd != nil {
                ClipAuthoringBar()
            }
            ScrubberView()
            controlRow
        }
        .padding(10)
        .background(Theme.Surface.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 14) {
            transportButton("backward.end.fill", help: "Previous item (\(model.keyMap.labels.previousNext))") {
                model.goPrevious()
            }
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.Text.primary)
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space, 5)")
            transportButton("forward.end.fill", help: "Next item (\(model.keyMap.labels.previousNext))") {
                model.goNext()
            }
            transportButton(
                model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: model.isMuted ? "Unmute (M)" : "Mute (M)",
                on: model.isMuted
            ) { model.toggleMute() }
            transportButton(
                "repeat", help: model.isLooping ? "Looping — click to play once (L)" : "Loop (L)",
                on: model.isLooping
            ) { model.toggleLoop() }

            Text(timeText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Text.quaternary)

            Spacer()

            // Marking, from the transport rather than only from the
            // keyboard — the keys are faster, the buttons are findable.
            Button(model.pendingSegmentStart == nil ? "Mark in" : "Mark out") {
                model.pendingSegmentStart == nil
                    ? model.openSegmentMark()
                    : model.closeSegmentMark(as: .song)
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .help("Open a segment at the playhead (\(model.keyMap.labels.segmentOpen)), close it (\(model.keyMap.labels.segmentClose)); C closes it as a clip")

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(String(format: "%g×", rate)) {
                        model.playbackRate = Float(rate)
                    }
                }
            } label: {
                Text(String(format: "%g×", model.playbackRate))
                    .font(Theme.mono(11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 58)
            .help("Playback speed")
        }
    }

    private func transportButton(
        _ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(on ? Theme.Accent.amber : Theme.Text.tertiary)
                .frame(width: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var timeText: String {
        TransportBarTime.format(model.currentSeconds)
            + " / " + TransportBarTime.format(model.durationSeconds)
    }
}

/// An open mark, stated plainly with the key that closes it.
private struct MarkingIndicator: View {
    @Environment(PlayerModel.self) private var model
    let start: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.Accent.amber).frame(width: 7, height: 7)
            Text("marking from \(TransportBarTime.format(start)) — \(model.keyMap.labels.segmentClose) to close")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Accent.amber)
            Spacer()
            Button("Cancel · esc") { model.cancelSegmentMark() }
                .buttonStyle(.plain)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.horizontal, 4)
    }
}

/// The keyboard map's four flags, as toolbar toggles. This is now their
/// only home — the info strip under the video is gone.
private struct FlagButtons: View {
    @Environment(PlayerModel.self) private var model
    let item: MediaItem

    var body: some View {
        HStack(spacing: 6) {
            flag(.favorite, on: item.isFavorite, "★", "Favorite (F)")
            flag(.needsReview, on: item.needsReview, "⟳", "Needs review (R)")
            flag(.playbackIssue, on: item.playbackIssue, "⚠", "Playback issue (W)")
            flag(.markedForDeletion, on: item.markedForDeletion, "⌫", "Marked for deletion (D)")
        }
    }

    private func flag(
        _ flag: PlayerToggleFlag, on: Bool, _ glyph: String, _ help: String
    ) -> some View {
        Button {
            model.perform(action(for: flag))
        } label: {
            Text(glyph)
                .font(Theme.ui(12))
                .foregroundStyle(on ? Theme.Accent.amber : Theme.Text.disabled)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(on ? Theme.Surface.iconTileSelected : .clear)
                        .stroke(on ? Theme.Accent.amber : Theme.Border.subtleButton, lineWidth: 1))
        }
        .buttonStyle(.plain)
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

/// Triage mode: the only place a flag key advances.
private struct TriageButton: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Button {
            model.triageMode.toggle()
            model.zone = .video
        } label: {
            Text(model.triageMode ? "Triage on · \(model.triageCount) done" : "Triage pass")
                .font(Theme.ui(12))
                .foregroundStyle(model.triageMode ? Theme.Accent.amber : Theme.Text.tertiary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .fill(model.triageMode ? Theme.Surface.iconTileSelected : .clear)
                        .stroke(
                            model.triageMode ? Theme.Border.activeControl : Theme.Border.subtleButton,
                            lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("\(model.keyMap.labels.triage) mark the item and move to the next one. Outside the mode they toggle and stay put.")
    }
}

/// Which panels are up. Each is a toggle, and Tab only visits what is
/// actually on screen.
private struct PanelToggles: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            toggle(.tags, "Tags")
            toggle(.segments, "Segments")
            toggle(.queue, "Queue")
            toggle(.text, "Text")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.segmentTrack)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func toggle(_ panel: PlayerPanel, _ label: String) -> some View {
        let on = model.panels[panel]
        return Button {
            model.togglePanel(panel)
        } label: {
            Text(label)
                .font(Theme.ui(11.5, on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.Text.primary : Theme.Text.quaternary)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(on ? Theme.Surface.segmentSelected : .clear))
        }
        .buttonStyle(.plain)
        .help(panel == .text ? "On-screen text — timestamped, click to seek" : "\(label) panel")
    }
}

// MARK: - Footer

/// 30 pt across the bottom: which zone has the keys, what they do there,
/// and where you are in the listing. The hints read their key labels
/// from the chosen map, so they cannot disagree with it.
private struct FocusFooter: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.availableZones, id: \.self) { zone in
                Button {
                    model.zone = zone
                } label: {
                    Text(zone.displayName)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(
                            model.zone == zone ? Theme.Accent.amber : Theme.Text.disabled)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(model.zone == zone
                                    ? Theme.Surface.iconTileSelected : Theme.Surface.iconTile))
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Theme.Border.standard).frame(width: 1, height: 14)
            Text(hint)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .lineLimit(1)
            Spacer(minLength: 0)
            if AppSettingsStore.shared.current.infoBar.showsPosition,
               let item = model.item, !model.playlist.isEmpty,
               let index = model.playlist.firstIndex(of: item.id) {
                Text("\(index + 1) of \(model.playlist.count)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.quaternary)
                    .help("Position in the filtered listing this item was opened from")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var hint: String {
        let labels = model.keyMap.labels
        return model.zone == .video
            ? "\(labels.segmentOpen) \(labels.segmentClose) segment · \(labels.triage) triage · numpad seek · Tab moves focus"
            : "Esc releases to video · numpad seek still works · Tab moves focus"
    }
}

// MARK: - The right rail

/// Tags over segments, one rail. They share the height and never resolve
/// against each other — the rail's floor is the tag panel's floor.
private struct SegmentsAndTagsRail: View {
    @Environment(PlayerModel.self) private var model
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if model.panels.tags {
                TagPanelView()
                    .frame(maxHeight: .infinity)
                    .layoutPriority(model.panels.segments ? 1.35 : 1)
                    .zoneRing(.tags)
            }
            if model.panels.tags, model.panels.segments {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }
            if model.panels.segments {
                SegmentsPanel()
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                    .zoneRing(.segments)
            }
        }
        .frame(width: width)
        .background(Theme.Surface.raised)
    }
}

/// Songs, clips and hide blocks in one list. They read as the same thing
/// — a named range on the timeline — and are deliberately not the same
/// record: a song can be tagged and browsed, a hide block is an
/// instruction to an edit job and never reaches the grid.
private struct SegmentsPanel: View {
    @Environment(PlayerModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Segments").modifier(Theme.sectionLabel())
                Spacer()
                Text(model.segments.isEmpty
                    ? "" : "\(model.songCount) songs · \(model.clipCount) clips")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                ZoneBadge(zone: .segments)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if model.segments.isEmpty {
                Text("No songs or clips yet. Press \(model.keyMap.labels.segmentOpen) to open a segment, \(model.keyMap.labels.segmentClose) to close it.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.segments) { row in
                            SegmentRowView(
                                row: row,
                                renaming: $renaming,
                                draftName: $draftName)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegmentRowView: View {
    @Environment(PlayerModel.self) private var model
    let row: SegmentRow
    @Binding var renaming: UUID?
    @Binding var draftName: String

    var body: some View {
        let selected = model.selectedSegmentID == row.id
        HStack(spacing: 8) {
            Text(row.kind.badge)
                .font(Theme.mono(9, .bold))
                .foregroundStyle(hue)
                .padding(.vertical, 1.5)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(hue.opacity(0.15)))
            if renaming == row.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .onSubmit {
                        model.renameSegment(row.id, to: draftName)
                        renaming = nil
                    }
            } else {
                Text(row.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(selected ? Theme.Text.primary : Theme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text("\(TransportBarTime.format(row.start))–\(TransportBarTime.format(row.end))")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.Text.disabled)
            Button {
                model.playSegment(row)
            } label: {
                Image(systemName: "play.fill").font(Theme.ui(9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Text.tertiary)
            .help("Play from \(TransportBarTime.format(row.start))")
            Button {
                model.removeSegment(row)
            } label: {
                Image(systemName: "xmark").font(Theme.ui(9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Text.disabled)
            .help(row.kind == .hide
                ? "Remove this hide block — the file is untouched"
                : "Remove this segment — the range's name, not the media")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(selected ? Theme.Surface.selectedSegment : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Theme.Accent.amber)
                    .frame(width: Theme.Border.selectionInsetWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedSegmentID = row.id
            model.zone = .segments
        }
        .onTapGesture(count: 2) {
            guard row.isRenameable else { return }
            draftName = row.name
            renaming = row.id
        }
    }

    private var hue: Color {
        switch row.kind {
        case .song: Theme.Segment.song
        case .clip: Theme.Segment.clip
        case .hide: Theme.Segment.hide
        }
    }
}

/// The Tab badge on a panel header — amber while that zone holds focus.
struct ZoneBadge: View {
    @Environment(PlayerModel.self) private var model
    let zone: PlayerZone

    var body: some View {
        let active = model.zone == zone
        Text("Tab")
            .font(Theme.mono(9))
            .foregroundStyle(active ? Theme.Accent.amber : Theme.Text.disabled)
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(active ? Theme.Surface.iconTileSelected : Theme.Surface.iconTile))
    }
}

// MARK: - Video surface

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
            // A live panel drag resizes this layer every frame; implicit
            // animations would smear each step toward the next. Track
            // the drag exactly instead.
            playerLayer.actions = [
                "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
            ]
            layer = playerLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}

// MARK: - Scrubber

/// The timeline: waveform-backed for audio, hover previews for video,
/// click/drag to seek, and the segment lanes — songs above the waveform,
/// clips below, hide blocks shaded across it.
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
        // Read every model value ONCE, here: the Canvas draw closure is
        // not main-actor isolated, and reaching into an @Observable model
        // from inside it does not compile (and would be a data race if it
        // did).
        let duration = model.durationSeconds
        let progress: CGFloat = duration > 0
            ? CGFloat((model.currentSeconds / duration).clamped01) : 0
        let segments = model.segments
        let selectedID = model.selectedSegmentID
        let clipRange: (Double, Double)? = model.item?.clipStartSeconds.map {
            ($0, model.item?.clipEndSeconds ?? duration)
        }
        let markStart = model.pendingSegmentStart
        Canvas { context, size in
            // Lanes: songs occupy the top 8 pt, clips the bottom 8, and
            // the waveform keeps the middle. Selecting a rail row lights
            // its bar, and vice versa.
            let laneHeight: CGFloat = 8
            let middle = CGRect(
                x: 0, y: laneHeight, width: size.width, height: size.height - laneHeight * 2)

            // Base track / waveform.
            if let peaks, !peaks.isEmpty {
                let barWidth = middle.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let barHeight = max(1, CGFloat(peak) * middle.height)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth,
                        y: middle.minY + (middle.height - barHeight) / 2,
                        width: max(barWidth - 0.5, 0.5),
                        height: barHeight)
                    let played = CGFloat(index) / CGFloat(peaks.count) <= progress
                    context.fill(
                        Path(rect),
                        with: .color(played ? Theme.Accent.amber : Theme.Text.disabled))
                }
            } else {
                let track = CGRect(
                    x: 0, y: middle.midY - 2, width: size.width, height: 4)
                context.fill(
                    Path(roundedRect: track, cornerRadius: 2),
                    with: .color(Theme.Border.raised))
                let played = CGRect(
                    x: 0, y: middle.midY - 2, width: size.width * progress, height: 4)
                context.fill(
                    Path(roundedRect: played, cornerRadius: 2),
                    with: .color(Theme.Accent.amber))
            }

            guard duration > 0 else { return }
            func x(_ seconds: Double) -> CGFloat {
                size.width * CGFloat((seconds / duration).clamped01)
            }

            for row in segments {
                let x0 = x(row.start), x1 = x(row.end)
                let selected = selectedID == row.id
                switch row.kind {
                case .hide:
                    // Hide blocks shade the whole height: they skip during
                    // playback, so they are not a lane, they are a gap.
                    context.fill(
                        Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                        with: .color(Theme.Segment.hide.opacity(selected ? 0.34 : 0.18)))
                case .song, .clip:
                    let hue = row.kind == .song ? Theme.Segment.song : Theme.Segment.clip
                    let y = row.kind == .song ? 0 : size.height - laneHeight
                    context.fill(
                        Path(roundedRect: CGRect(
                            x: x0, y: y, width: max(2, x1 - x0), height: laneHeight - 2),
                            cornerRadius: 2),
                        with: .color(hue.opacity(selected ? 1 : 0.55)))
                }
            }

            // The clip range of the item being PLAYED (when the item is
            // itself a clip), shaded behind everything.
            if let (start, end) = clipRange {
                context.fill(
                    Path(CGRect(x: x(start), y: 0, width: x(end) - x(start), height: size.height)),
                    with: .color(Theme.Accent.amber.opacity(0.12)))
            }

            // An open mark, from its start to the playhead.
            if let start = markStart {
                context.fill(
                    Path(CGRect(
                        x: x(start), y: 0,
                        width: max(1, size.width * progress - x(start)), height: size.height)),
                    with: .color(Theme.Accent.amber.opacity(0.16)))
            }

            // Playhead.
            context.fill(
                Path(CGRect(x: size.width * progress - 0.75, y: 0, width: 1.5, height: size.height)),
                with: .color(Theme.Text.primary))
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
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(Theme.Surface.iconTile))
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

/// The in-progress clip range from the older two-point authoring path:
/// shown while either point is set, saved once both are.
private struct ClipAuthoringBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors").foregroundStyle(Theme.Segment.clip)
            Text(rangeText)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.secondary)
            if model.pendingClipReady {
                TextField("Clip name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .frame(width: 180)
                Button("Save Clip") {
                    model.savePendingClip(named: name)
                    name = ""
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Text("set the other point")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer()
            Button("Cancel") { model.cancelPendingClip() }
                .buttonStyle(.plain)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.horizontal, 4)
    }

    private var rangeText: String {
        let start = model.pendingClipStart.map(TransportBarTime.format) ?? "—"
        let end = model.pendingClipEnd.map(TransportBarTime.format) ?? "—"
        return "\(start) → \(end)"
    }
}

// MARK: - Handles

/// Edge-drag handles, sidebar-style. They sit on the PANEL side of the
/// tap-to-refocus boundary so resizing never fights the focus gesture.
private struct VerticalResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Rectangle()
            .fill(Theme.Border.standard)
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Global space: the handle itself moves as the panel
                // resizes, so LOCAL translation is measured against a
                // moving origin — width oscillates every frame and the
                // drag flickers. (AppKit's sidebar divider tracks in
                // window coordinates for the same reason.)
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() })
    }
}

private struct HorizontalResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Rectangle()
            .fill(Theme.Border.standard)
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Global space — same moving-origin flicker as the
                // vertical handle.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.height) }
                    .onEnded { _ in onEnd() })
    }
}

// MARK: - Queue

/// The play queue: ONE fully-visible row of tiles — the browse grid's
/// tile at a different size — scrolling horizontally, current item ringed
/// and kept centered. Cell math is deterministic: the metadata reserve is
/// computed from the active view and the thumbnail takes the rest, so
/// nothing can clip at any divider height. The queue reflects the
/// playlist SNAPSHOT the player opened with.
private struct QueuePanel: View {
    @Environment(PlayerModel.self) private var model
    let height: CGFloat

    var body: some View {
        let grid = GridDisplaySettings.shared.grid
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
                            .transition(.opacity)
                            .onTapGesture {
                                model.zone = .queue
                                model.load(itemID: item.id)
                            }
                    }
                }
                .padding(6)
                // Cross-fade rather than a hard swap: the strip reshaping
                // silently under you while you are watching something is
                // the jarring part. Same constant as the grid — two
                // surfaces resettling at different speeds off one click
                // reads as a bug.
                .animation(
                    .easeInOut(duration: Theme.Motion.listingSettle),
                    value: model.queueItems.map(\.id))
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
        .background(Theme.Surface.toolbar)
        .zoneRing(.queue)
    }
}

/// One queue tile. Drawn by the same `TileCard` as the browse grid, from
/// the same active view — the queue IS the grid at a different size, and
/// two implementations of "what a tile says" is how they drift apart.
/// The join-backed values (tags, missing categories) stay empty here: the
/// queue does not run the grid's batch queries.
private struct QueueCell: View {
    @Environment(PlayerModel.self) private var model
    let item: MediaItem
    let thumbHeight: CGFloat
    let grid: GridSettings
    let isCurrent: Bool
    @State private var thumbnail: NSImage?

    /// Deterministic reserve for the strips above and below the
    /// thumbnail; the panel divides its height into thumbnail + this, so
    /// cells always fit whole at any divider height.
    static func metadataHeight(for grid: GridSettings) -> CGFloat {
        let view = grid.activeView
        let strips = [TileSlot.above, .below].filter { !view.entries(in: $0).isEmpty }
        return strips.isEmpty ? 0 : CGFloat(strips.count) * 16 + 5
    }

    private var cellWidth: CGFloat { thumbHeight * 16 / 9 }

    var body: some View {
        TileCard(
            item: item,
            context: TileContext(),
            view: grid.activeView,
            grid: grid,
            thumbnail: thumbnail,
            thumbnailHeight: thumbHeight)
            .frame(width: cellWidth)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Theme.Accent.amber.opacity(0.15) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrent ? Theme.Accent.amber : Color.clear, lineWidth: 2))
            .help(item.fileName)
            .task(id: item.id) {
                let data = await ThumbnailProvider.shared.thumbnailData(
                    itemID: item.id, libraryID: model.libraryID,
                    fileURL: model.queueFileURL(for: item),
                    durationSeconds: item.durationSeconds)
                thumbnail = data.flatMap(NSImage.init(data:))
            }
    }
}

// MARK: - The keyboard map

/// Both maps side by side: the chooser, and thereafter the cheat sheet.
/// Only four rows differ, and they are the highlighted ones.
private struct KeyMapSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choice = AppSettingsStore.shared.current.keyMap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard map")
                    .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Two maps disagree on four rows. Pick one — the hints throughout the window follow it.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            HStack(spacing: 0) {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                header("Web map", style: .web)
                header("Mac map", style: .mac)
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(KeyMapStyle.comparison) { row in
                        HStack(spacing: 0) {
                            Text(row.label)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(
                                    row.differs ? Theme.Text.primary : Theme.Text.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            cell(row.web, differs: row.differs, active: choice == .web)
                            cell(row.mac, differs: row.differs, active: choice == .mac)
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Theme.Border.standard).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(alignment: .top, spacing: 10) {
                Text("Rows that differ are highlighted. Everything else is identical in both maps.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Done") {
                    AppSettingsStore.shared.update { $0.keyMap = choice }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .background(Theme.Surface.dialog)
    }

    private func header(_ label: String, style: KeyMapStyle) -> some View {
        Button {
            choice = style
        } label: {
            Text(label)
                .font(Theme.ui(11.5, choice == style ? .semibold : .regular))
                .foregroundStyle(choice == style ? Theme.Accent.amber : Theme.Text.quaternary)
                .frame(width: 150)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(choice == style ? Theme.Surface.selectedRow : .clear)
                        .stroke(
                            choice == style ? Theme.Border.activeCard : Theme.Border.subtleButton,
                            lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func cell(_ keys: String, differs: Bool, active: Bool) -> some View {
        Text(keys)
            .font(Theme.mono(11.5))
            .foregroundStyle(
                differs ? (active ? Theme.Accent.amber : Theme.Text.quaternary)
                    : Theme.Text.disabled)
            .frame(width: 150)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(differs && active ? Theme.Surface.selectedRow : .clear))
    }
}

extension VideoAnchor {
    /// Where the fitted video sits inside the stage (#92). Placement
    /// only — the fitted-size math never reads this.
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        case .center: .center
        }
    }
}
