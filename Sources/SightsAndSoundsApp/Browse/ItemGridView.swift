import SwiftUI
import SightsAndSoundsKit

struct ItemGridView: View {
    @Environment(BrowseModel.self) private var model

    // Cell size is a view option; the adaptive maximum tracks the
    // chosen minimum so cells stay near the picked size.
    private var columns: [GridItem] {
        let size = AppSettingsStore.shared.current.grid.thumbnailSize
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
        let grid = AppSettingsStore.shared.current.grid
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
                overlayBadges
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
            if grid.showsTags, let names = model.itemTagNames[item.id], !names.isEmpty {
                Text(names.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if grid.showsMissingCategories,
               let missing = model.itemMissingCategories[item.id], !missing.isEmpty {
                Text("Missing: \(missing.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Categories this item has no tag in yet")
            }
            HStack(spacing: 6) {
                if grid.showsDuration, let duration = item.durationSeconds {
                    Text(Self.format(duration: duration))
                }
                if grid.showsFileSize {
                    Text(Self.format(bytes: item.fileSize))
                }
                if grid.showsDimensions, let w = item.width, let h = item.height {
                    Text("\(w)×\(h)")
                }
                if grid.showsImportDate {
                    Text(item.ingestDate.formatted(date: .abbreviated, time: .omitted))
                        .help("Import date")
                }
                if grid.showsViewCount, item.watchCount > 0 {
                    Text("▶ \(item.watchCount)")
                        .help("Watched \(item.watchCount)×")
                }
                Spacer()
                if grid.showsFavorite, item.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                if grid.showsReviewed, item.needsReview {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Needs review")
                }
                if grid.showsDeleted, item.markedForDeletion {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .help("Staged for deletion")
                }
                if grid.showsClip, item.isClip {
                    Image(systemName: "scissors")
                        .help(item.isExportedClip ? "Exported clip" : "Embedded clip")
                }
                if grid.showsDuplicate, model.duplicateFlaggedIDs.contains(item.id) {
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
/// each thumbnail — what shows and how big, in one place. Writes
/// through AppSettings and pokes a refresh so join-backed fields load.
struct GridViewOptions: View {
    let onChange: () -> Void
    @State private var grid = AppSettingsStore.shared.current.grid

    var body: some View {
        Form {
            Section("Thumbnail size") {
                Slider(value: $grid.thumbnailSize, in: 120...400) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.3x3")
                } maximumValueLabel: {
                    Image(systemName: "square")
                }
            }
            Section("Fields") {
                Toggle("Filename", isOn: $grid.showsFileName)
                Toggle("Path", isOn: $grid.showsPath)
                Toggle("Tags", isOn: $grid.showsTags)
                Toggle("Missing category tags", isOn: $grid.showsMissingCategories)
                Toggle("Import date", isOn: $grid.showsImportDate)
                Toggle("View count", isOn: $grid.showsViewCount)
                Toggle("Duration", isOn: $grid.showsDuration)
                Toggle("File size", isOn: $grid.showsFileSize)
                Toggle("Dimensions", isOn: $grid.showsDimensions)
                Toggle("Favorite", isOn: $grid.showsFavorite)
                Toggle("Needs review", isOn: $grid.showsReviewed)
                Toggle("Staged for deletion", isOn: $grid.showsDeleted)
                Toggle("Pending duplicate", isOn: $grid.showsDuplicate)
                Toggle("Clip", isOn: $grid.showsClip)
            }
        }
        .formStyle(.grouped)
        .frame(width: 280, height: 520)
        .onChange(of: grid) {
            AppSettingsStore.shared.update { $0.grid = grid }
            onChange()
        }
    }
}
