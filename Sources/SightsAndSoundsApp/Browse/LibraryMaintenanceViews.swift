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

/// The purge flow: count what's staged, confirm in plain words, report
/// what happened. Only flagged rows are ever touched.
struct PurgeButton: View {
    @Environment(BrowseModel.self) private var model
    @State private var confirming = false
    @State private var flaggedCount = 0
    @State private var resultText: String?

    var body: some View {
        Button("Purge Deleted Items…", systemImage: "trash") {
            flaggedCount = (try? model.library.writer.read {
                try MediaItem.filter(sql: "markedForDeletion = 1").fetchCount($0)
            }) ?? 0
            confirming = true
        }
        .confirmationDialog(
            flaggedCount == 0
                ? "No items are marked for deletion."
                : "Permanently delete \(flaggedCount) marked items and their staged files? This cannot be undone.",
            isPresented: $confirming
        ) {
            if flaggedCount > 0 {
                Button("Delete \(flaggedCount) Items", role: .destructive) { purge() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Purge Complete", isPresented: .constant(resultText != nil)) {
            Button("OK") { resultText = nil }
        } message: {
            Text(resultText ?? "")
        }
    }

    private func purge() {
        do {
            let outcome = try model.library.purgeDeleted()
            var text = "\(outcome.rowsDeleted) items removed, \(outcome.filesDeleted) files deleted."
            if !outcome.fileFailures.isEmpty {
                text += " \(outcome.fileFailures.count) files could not be deleted and their items were kept."
            }
            resultText = text
            model.refreshAll()
        } catch {
            resultText = "Purge failed: \(error)"
        }
    }
}
