import SwiftUI
import SightsAndSoundsKit

struct ItemGridView: View {
    @Environment(BrowseModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]

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
    @Environment(\.openWindow) private var openWindow
    let item: MediaItem
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.kind == .audio ? "waveform" : "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                overlayBadges
            }
            Text(item.fileName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                if let duration = item.durationSeconds {
                    Text(Self.format(duration: duration))
                }
                Text(Self.format(bytes: item.fileSize))
                Spacer()
                if item.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                if item.needsReview {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Needs review")
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
            if item.parentMediaItemID != nil && !item.isExportedClip {
                Button("Export Clip to File", systemImage: "scissors") {
                    model.exportClip(item)
                }
                .disabled(!model.isOnline(item))
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
        openWindow(id: "player", value: PlayerRequest(
            libraryID: model.libraryID, itemID: item.id,
            playlist: model.items.map(\.id)))
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
