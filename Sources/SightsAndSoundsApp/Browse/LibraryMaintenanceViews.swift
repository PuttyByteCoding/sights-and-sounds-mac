import SwiftUI
import SightsAndSoundsKit

/// Move history: every logged file move, revertible until reverted.
struct MoveHistoryView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var logs: [FileMoveLog] = []
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if logs.isEmpty {
                ContentUnavailableView(
                    "No Moves Yet", systemImage: "arrow.turn.up.right",
                    description: Text("Staging, reorganization and manual moves appear here, each revertible."))
            } else {
                List(logs) { log in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.fileName).font(.callout)
                            Text("\(log.fromPath)  →  \(log.toPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(log.movedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if log.revertedAt != nil {
                            Text("reverted").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Revert") { revert(log) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear { reload() }
    }

    private func reload() {
        do {
            logs = try model.library.moveLogs()
        } catch { errorText = "\(error)" }
    }

    private func revert(_ log: FileMoveLog) {
        do {
            try model.library.revertMove(log.id)
            errorText = nil
            reload()
            model.refreshAll()
        } catch { errorText = "\(error)" }
    }
}

/// Purging moved into the Review window, where the marked files can
/// actually be seen. A count in a confirmation dialog was not
/// reviewable: you could not tell what the 47 items were, and the mark
/// could be four months old.
struct PurgeButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(BrowseModel.self) private var model

    var body: some View {
        Button("Review Marked Items…", systemImage: "trash") {
            openWindow(
                id: "aux", value: AuxWindowRequest(libraryID: model.libraryID, kind: .review))
        }
        .help("The delete list, with each file, why it is there, and what it reclaims")
    }
}
