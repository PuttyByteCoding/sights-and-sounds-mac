import SightsAndSoundsKit
import SwiftUI

/// What "Remove from Library…" was asked about: the items, and the
/// segments on them that are not saved as files, which would go too.
struct RemovalRequest: Identifiable, Equatable {
    let items: [MediaItem]
    let unsaved: [LibraryDatabase.UnsavedSegments]
    var id: UUID { items.first?.id ?? UUID() }

    var itemIDs: [UUID] { items.map(\.id) }
    var unsavedCount: Int { unsaved.reduce(0) { $0 + $1.segmentIDs.count } }
}

extension BrowseModel {
    /// Ask before removing: the items, and what would go with them.
    func removalRequest(for items: [MediaItem]) -> RemovalRequest? {
        guard !items.isEmpty else { return nil }
        let unsaved = (try? library.unsavedSegments(of: items.map(\.id))) ?? []
        return RemovalRequest(items: items, unsaved: unsaved)
    }

    /// Remove the items from the library, leaving the files where they
    /// are — writing their tags into the files first if asked, so what the
    /// library knew travels with them. Queued, like every file operation;
    /// the grid follows the rows out.
    func removeFromLibrary(_ request: RemovalRequest, writingTagsFirst: Bool, runner: JobRunner) {
        Task {
            do {
                _ = try await RemoveFromLibraryJob.enqueue(
                    on: runner, itemIDs: request.itemIDs, writeTagsFirst: writingTagsFirst)
                await runner.startDraining()
            } catch {
                errorMessage = "Could not remove from the library: \(error)"
            }
        }
    }
}

/// The question. Files stay; the library forgets. Tags can be written
/// into the files first — on by default, because the alternative is
/// losing what was typed.
struct RemoveFromLibrarySheet: View {
    let request: RemovalRequest
    let onRemove: (_ writingTagsFirst: Bool) -> Void
    let onCancel: () -> Void
    @State private var writeTagsFirst = true

    private var count: Int { request.items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1
                ? "Remove “\(request.items[0].fileName)” from the library?"
                : "Remove \(count) items from the library?")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text("The files stay where they are. The library forgets them: their tags, notes, segments and history go. A later scan lists them as new.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if request.unsavedCount > 0 {
                Text(request.unsavedCount == 1
                    ? "1 segment on these videos is not saved as a file of its own. It goes with the video. Export it first to keep it."
                    : "\(request.unsavedCount) segments on these videos are not saved as files of their own. They go with the videos. Export them first to keep them.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Status.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $writeTagsFirst) {
                Text("Write tags into the files first")
                    .font(Theme.ui(12))
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.Text.secondary)
            .help("An item whose tags cannot be written (file offline, tools missing, the write fails) stays in the library")
            HStack(spacing: 9) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Remove" : "Remove \(count)") { onRemove(writeTagsFirst) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Theme.Surface.dialog)
    }
}
