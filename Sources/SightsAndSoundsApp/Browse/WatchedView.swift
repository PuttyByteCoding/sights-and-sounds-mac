import AppKit
import SwiftUI
import SightsAndSoundsKit

/// What you have watched, most recent first.
///
/// Deliberately named *Recently Watched* rather than *History*: it reads
/// the columns the player already maintains, so it is one row per item
/// carrying the latest date. Watching something three times is a single
/// row reading 3 — the window says so in its own footer rather than
/// implying a timeline it cannot produce.
struct WatchedView: View {
    @Environment(BrowseModel.self) private var model

    @State private var rows: [MediaItem] = []
    @State private var total = 0
    @State private var loadError: String?

    private static let displayLimit = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            if let loadError {
                ContentUnavailableView(
                    "Could Not Read the History",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if rows.isEmpty {
                empty
            } else {
                table
            }
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Theme.Surface.content)
        .task { reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Recently Watched").modifier(Theme.sectionLabel(Theme.Accent.amber))
            Text("\(total) watched")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
            Spacer()
            Button("Refresh") { reload() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing watched yet")
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.Text.quaternary)
            Text("Play something and it lands here, with where you stopped.")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Text.disabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Item").modifier(Theme.sectionLabel())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Last watched").modifier(Theme.sectionLabel())
                    .frame(width: 150, alignment: .leading)
                Text("Plays").modifier(Theme.sectionLabel())
                    .frame(width: 56, alignment: .trailing)
                Text("Stopped at").modifier(Theme.sectionLabel())
                    .frame(width: 110, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: 31)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row($0) }
                }
            }
        }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.relativePath)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.disabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.lastWatchedAt.map(Self.relative) ?? "—")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 150, alignment: .leading)

            Text("\(item.watchCount)")
                .font(Theme.mono(11))
                .foregroundStyle(item.watchCount == 0 ? Theme.Text.zeroCount : Theme.Text.disabled)
                .frame(width: 56, alignment: .trailing)

            stopped(item)
                .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { reveal(item) }
                .disabled(!model.isOnline(item))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard.opacity(0.5)).frame(height: 1)
        }
    }

    /// Finished, or the position it will resume from. `recordPlaybackStop`
    /// clears the resume near either edge, so "no position but not
    /// completed" genuinely means "barely started".
    @ViewBuilder
    private func stopped(_ item: MediaItem) -> some View {
        if item.completed {
            ThemeBadge(
                text: "finished", fill: Theme.Surface.iconTile,
                foreground: Theme.Status.green)
        } else if let resume = item.resumePositionSeconds {
            Text(Self.timecode(resume))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Accent.amber)
        } else {
            Text("just started")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(total > Self.displayLimit
                ? "Showing the \(Self.displayLimit) most recent of \(total)."
                : "One row per item, carrying its most recent play — watching something twice updates the row rather than adding one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func reload() {
        do {
            rows = try model.library.recentlyWatched(limit: Self.displayLimit)
            total = try model.library.watchedItemCount()
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    private func reveal(_ item: MediaItem) {
        guard let url = try? model.library.resolvedFileURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
