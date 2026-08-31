import AppKit
import SwiftUI
import SightsAndSoundsKit

/// The company a tag keeps: a thumbnail grid of the items carrying it.
///
/// This is a CONFIRMATION surface — "is this really the taper I think it
/// is?" gets answered by seeing what else wears the tag, without leaving
/// the tagging flow or disturbing the browse filter. Deliberately
/// read-only: it takes only the library handles, never a model, so the
/// player, the sidebar and a grid tile can all present it identically.
struct TagItemsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tag: Tag
    let categoryName: String?
    let library: LibraryDatabase
    let libraryID: UUID

    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var loadError: String?

    private static let displayLimit = 60
    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let loadError {
                ContentUnavailableView(
                    "Could Not Load", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing carries this tag yet")
                        .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                    Text("It exists in the vocabulary, but no item wears it.")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            cell(item)
                        }
                    }
                    .padding(14)
                    if total > items.count {
                        Text("and \(total - items.count) more")
                            .font(Theme.ui(Theme.TypeScale.secondary))
                            .foregroundStyle(Theme.Text.quaternary)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.Surface.dialog)
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            return .ignored
        }
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.categoryHue(0))
                .frame(width: 7, height: 7)
            Text(tag.name)
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            if let categoryName {
                Text(categoryName)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }
            Spacer()
            Text("\(total) item\(total == 1 ? "" : "s")")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
            Button("Done") { dismiss() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func cell(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TagItemThumb(item: item, library: library, libraryID: libraryID)
            Text(item.fileName)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(item.relativePath)
    }

    private func load() {
        do {
            (items, total) = try library.items(withTag: tag.id, limit: Self.displayLimit)
        } catch {
            loadError = "\(error)"
        }
    }
}

private struct TagItemThumb: View {
    let item: MediaItem
    let library: LibraryDatabase
    let libraryID: UUID
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.Surface.stage)
                Image(systemName: item.kind == .audio ? "waveform" : "film")
                    .font(Theme.ui(18))
                    .foregroundStyle(Theme.Text.disabled)
            }
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .task(id: item.id) {
            // Cached thumbnails render even offline; a missing one just
            // stays a placeholder — confirmation must not hang on a
            // sleeping drive.
            let fileURL = try? library.resolvedFileURL(for: item)
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id, libraryID: libraryID, fileURL: fileURL ?? nil,
                durationSeconds: item.durationSeconds)
            if let data { thumbnail = NSImage(data: data) }
        }
    }
}
