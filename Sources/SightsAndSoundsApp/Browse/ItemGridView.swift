import SwiftUI
import SightsAndSoundsKit

struct ItemGridView: View {
    @Environment(BrowseModel.self) private var model

    // Cell size is a view option; the adaptive maximum tracks the
    // chosen minimum so cells stay near the picked size.
    private var columns: [GridItem] {
        // Observable read — the View Options slider resizes cells LIVE.
        let size = GridDisplaySettings.shared.grid.thumbnailSize
        return [GridItem(.adaptive(minimum: size, maximum: size * 1.4), spacing: 12)]
    }

    var body: some View {
        Group {
            if let error = model.errorMessage {
                ContentUnavailableView(
                    "Query Failed", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    model.filter.isEmpty ? "No Items" : "No Matches",
                    systemImage: model.filter.isEmpty ? "film.stack" : "line.3.horizontal.decrease.circle",
                    description: Text(model.filter.isEmpty
                        ? "Add a source and import media to fill this library."
                        : "Nothing matches the current filter."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.items) { item in
                            ItemCell(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct ItemCell: View {
    @Environment(BrowseModel.self) private var model
    let item: MediaItem
    @State private var thumbnail: NSImage?

    var body: some View {
        let grid = GridDisplaySettings.shared.grid
        VStack(alignment: .leading, spacing: 4) {
            // Every thumbnail occupies the SAME 16:9 cell — portrait
            // videos letterbox (pillarbox) on black instead of inflating
            // their cell and making rows ragged.
            ZStack {
                Color.black
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .audio ? "waveform" : "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                ThumbnailCornerOverlays(
                    item: item, grid: grid,
                    tagNames: model.itemTagNames[item.id],
                    missingCategories: model.itemMissingCategories[item.id],
                    isDuplicate: model.duplicateFlaggedIDs.contains(item.id))
                overlayBadges
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if grid.fileName == .under {
                Text(item.fileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if grid.path == .under {
                Text(item.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if grid.tags == .under, let names = model.itemTagNames[item.id], !names.isEmpty {
                Text(names.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if grid.missingCategories == .under,
               let missing = model.itemMissingCategories[item.id], !missing.isEmpty {
                Text("Missing: \(missing.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Categories this item has no tag in yet")
            }
            HStack(spacing: 6) {
                if grid.duration == .under, let duration = item.durationSeconds {
                    Text(Self.format(duration: duration))
                }
                if grid.fileSize == .under {
                    Text(Self.format(bytes: item.fileSize))
                }
                if grid.dimensions == .under, let w = item.width, let h = item.height {
                    Text("\(w)×\(h)")
                }
                if grid.importDate == .under {
                    Text(item.ingestDate.formatted(date: .abbreviated, time: .omitted))
                        .help("Import date")
                }
                if grid.viewCount == .under, item.watchCount > 0 {
                    Text("▶ \(item.watchCount)")
                        .help("Watched \(item.watchCount)×")
                }
                Spacer()
                if grid.favorite == .under, item.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                if grid.reviewed == .under, item.needsReview {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Needs review")
                }
                if grid.deleted == .under, item.markedForDeletion {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .help("Staged for deletion")
                }
                if grid.clip == .under, item.isClip {
                    Image(systemName: "scissors")
                        .help(item.isExportedClip ? "Exported clip" : "Embedded clip")
                }
                if grid.duplicate == .under, model.duplicateFlaggedIDs.contains(item.id) {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.orange)
                        .help("In a pending duplicate pair")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play() }
        .contextMenu {
            Button("Play", systemImage: "play") { play() }
                .disabled(!model.isOnline(item))
            Divider()
            // File-location actions, not media operations.
            Button("Show in Finder", systemImage: "folder") { revealInFinder() }
                .disabled(!model.isOnline(item))
            Button("Open Terminal at Folder", systemImage: "terminal") { openTerminal() }
                .disabled(!model.isOnline(item))
            if item.parentMediaItemID != nil && !item.isExportedClip {
                Button("Export Clip to File", systemImage: "scissors") {
                    model.exportClip(item)
                }
                .disabled(!model.isOnline(item))
            }
            if item.markedForDeletion {
                Button("Restore from Deletion Staging", systemImage: "arrow.uturn.backward") {
                    try? model.library.unstage(.toDelete, itemID: item.id)
                    model.refreshAll()
                }
            }
            if item.playbackIssue {
                Button("Clear Playback Issue", systemImage: "play.circle") {
                    try? model.library.unstage(.playbackIssue, itemID: item.id)
                    model.refreshAll()
                }
            }
            if item.parentMediaItemID == nil {
                Divider()
                Button("Optimize (Faststart)", systemImage: "bolt") {
                    model.remux(item, mode: .optimize)
                }
                .disabled(!model.isOnline(item))
                Button("Repair Container", systemImage: "bandage") {
                    model.remux(item, mode: .repair)
                }
                .disabled(!model.isOnline(item))
                Menu("Encode a Copy") {
                    ForEach(EncodeJob.Preset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { model.encode(item, preset: preset) }
                    }
                }
                .disabled(!model.isOnline(item))
                Button("Write Tags to File", systemImage: "square.and.pencil") {
                    model.writeTags(itemIDs: [item.id], scope: item.fileName)
                }
                .disabled(!model.isOnline(item))
                let snapshots = model.snapshots(of: item.id)
                if !snapshots.isEmpty {
                    Menu("Restore Embedded Tags") {
                        ForEach(snapshots) { snapshot in
                            Button("\(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) (\(snapshot.source.rawValue))") {
                                model.restoreSnapshot(snapshot.id)
                            }
                        }
                    }
                    .disabled(!model.isOnline(item))
                }
                Button("Scan On-Screen Text (OCR)", systemImage: "text.viewfinder") {
                    model.scanText(item)
                }
                .disabled(!model.isOnline(item) || item.kind != .video)
                Button("Join Folder's Files", systemImage: "link") {
                    model.joinFolder(of: item)
                }
                .disabled(!model.isOnline(item))
                if model.hasHideBlocks(item) {
                    Button("Export Copy Without Hidden Blocks", systemImage: "eye.slash") {
                        model.removeBlocks(item)
                    }
                    .disabled(!model.isOnline(item))
                }
            }
        }
        .task(id: item.id) {
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id,
                libraryID: model.libraryID,
                fileURL: model.fileURL(for: item),
                durationSeconds: item.durationSeconds)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    @ViewBuilder private var overlayBadges: some View {
        if !model.isOnline(item) {
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "externaldrive.badge.xmark")
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .help("Source offline — playback unavailable")
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private func play() {
        guard model.isOnline(item) else { return }
        model.playerRequest = PlayerRequest(
            libraryID: model.libraryID, itemID: item.id,
            playlist: model.items.map(\.id))
    }

    // An embedded clip resolves to its parent's file — the file on disk.
    private func revealInFinder() {
        guard let url = model.fileURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openTerminal() {
        guard let url = model.fileURL(for: item) else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal")
        else {
            model.errorMessage = "Terminal.app could not be found."
            return
        }
        // Opening a DIRECTORY with Terminal starts a shell there.
        let model = model
        NSWorkspace.shared.open(
            [url.deletingLastPathComponent()], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                Task { @MainActor in
                    model.errorMessage = "Open Terminal failed: \(error.localizedDescription)"
                }
            }
        }
    }

    static func format(duration: Double) -> String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The toolbar popover: thumbnail size plus which fields show under
/// each thumbnail — what shows and how big, in one place. Drives the
/// live observable; persists on settle; refetches ONLY when a
/// join-backed field toggles (#91).
struct GridViewOptions: View {
    /// Fired only for tags / missing-categories / duplicate toggles —
    /// the fields whose data comes from batch queries.
    let onJoinFieldsChange: () -> Void

    var body: some View {
        @Bindable var display = GridDisplaySettings.shared
        Form {
            Section("Thumbnail size") {
                Slider(value: $display.grid.thumbnailSize, in: 120...400) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.3x3")
                } maximumValueLabel: {
                    Image(systemName: "square")
                } onEditingChanged: { editing in
                    // Live while dragging; settings.json only on settle.
                    if !editing { display.persist() }
                }
            }
            Section("Fields — where each one shows") {
                placementPicker("Filename", $display.grid.fileName)
                placementPicker("Path", $display.grid.path)
                placementPicker("Tags", $display.grid.tags)
                placementPicker("Missing category tags", $display.grid.missingCategories)
                placementPicker("Import date", $display.grid.importDate)
                placementPicker("View count", $display.grid.viewCount)
                placementPicker("Duration", $display.grid.duration)
                placementPicker("File size", $display.grid.fileSize)
                placementPicker("Dimensions", $display.grid.dimensions)
                placementPicker("Favorite", $display.grid.favorite)
                placementPicker("Needs review", $display.grid.reviewed)
                placementPicker("Staged for deletion", $display.grid.deleted)
                placementPicker("Pending duplicate", $display.grid.duplicate)
                placementPicker("Clip", $display.grid.clip)
                Text("Corner-placed info overlays the thumbnail on a dark backing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 280, height: 520)
        .onChange(of: GridDisplaySettings.shared.grid) { old, new in
            // Toggles persist immediately (cheap, discrete); the slider
            // persists via onEditingChanged instead.
            if old.thumbnailSize == new.thumbnailSize {
                GridDisplaySettings.shared.persist()
            }
            if (old.tags == .hidden) != (new.tags == .hidden)
                || (old.missingCategories == .hidden) != (new.missingCategories == .hidden)
                || (old.duplicate == .hidden) != (new.duplicate == .hidden) {
                onJoinFieldsChange()
            }
        }
    }

    private func placementPicker(
        _ label: String, _ selection: Binding<FieldPlacement>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(FieldPlacement.allCases, id: \.self) { placement in
                Text(placement.displayName).tag(placement)
            }
        }
    }
}

/// The corner-overlaid metadata clusters (#99): each populated corner
/// renders its fields on a dark translucent backing so text stays
/// readable over any frame. Shared by grid cells and queue cells; the
/// join-backed extras are optional — the queue omits them.
struct ThumbnailCornerOverlays: View {
    let item: MediaItem
    let grid: GridSettings
    var tagNames: [String]? = nil
    var missingCategories: [String]? = nil
    var isDuplicate = false

    var body: some View {
        corner(.topLeft, .topLeading)
        corner(.topRight, .topTrailing)
        corner(.bottomLeft, .bottomLeading)
        corner(.bottomRight, .bottomTrailing)
    }

    @ViewBuilder
    private func corner(_ placement: FieldPlacement, _ alignment: Alignment) -> some View {
        let lines = texts(at: placement)
        let icons = glyphs(at: placement)
        if !lines.isEmpty || !icons.isEmpty {
            VStack(
                alignment: alignment.horizontal == .trailing ? .trailing : .leading,
                spacing: 1
            ) {
                ForEach(lines, id: \.self) { line in
                    Text(line).lineLimit(1).truncationMode(.middle)
                }
                if !icons.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(icons, id: \.symbol) { icon in
                            Image(systemName: icon.symbol).foregroundStyle(icon.color)
                        }
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(4)
            .allowsHitTesting(false)
        }
    }

    private func texts(at placement: FieldPlacement) -> [String] {
        var lines: [String] = []
        if grid.fileName == placement { lines.append(item.fileName) }
        if grid.path == placement { lines.append(item.relativePath) }
        if grid.tags == placement, let tagNames, !tagNames.isEmpty {
            lines.append(tagNames.joined(separator: " · "))
        }
        if grid.missingCategories == placement,
           let missingCategories, !missingCategories.isEmpty {
            lines.append("Missing: " + missingCategories.joined(separator: ", "))
        }
        if grid.duration == placement, let duration = item.durationSeconds {
            lines.append(ItemCell.format(duration: duration))
        }
        if grid.fileSize == placement {
            lines.append(ItemCell.format(bytes: item.fileSize))
        }
        if grid.dimensions == placement, let width = item.width, let height = item.height {
            lines.append("\(width)×\(height)")
        }
        if grid.importDate == placement {
            lines.append(item.ingestDate.formatted(date: .abbreviated, time: .omitted))
        }
        if grid.viewCount == placement, item.watchCount > 0 {
            lines.append("▶ \(item.watchCount)")
        }
        return lines
    }

    private struct Glyph {
        var symbol: String
        var color: Color
    }

    private func glyphs(at placement: FieldPlacement) -> [Glyph] {
        var icons: [Glyph] = []
        if grid.favorite == placement, item.isFavorite {
            icons.append(Glyph(symbol: "star.fill", color: .yellow))
        }
        if grid.reviewed == placement, item.needsReview {
            icons.append(Glyph(symbol: "eye.trianglebadge.exclamationmark", color: .orange))
        }
        if grid.deleted == placement, item.markedForDeletion {
            icons.append(Glyph(symbol: "trash", color: .red))
        }
        if grid.clip == placement, item.isClip {
            icons.append(Glyph(symbol: "scissors", color: .white))
        }
        if grid.duplicate == placement, isDuplicate {
            icons.append(Glyph(symbol: "rectangle.on.rectangle", color: .orange))
        }
        return icons
    }
}
