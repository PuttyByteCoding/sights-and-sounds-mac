import SwiftUI
import SightsAndSoundsKit

/// ↑ ↓ through the history: the pure step, so the rule is tested. No
/// wrap — the history has a top and a bottom, and stepping off the
/// newest item onto the oldest would be a surprise mid-walk. Nothing
/// selected yet starts at the end the arrow came from.
enum HistoryNavigation {
    static func next(after selected: UUID?, in ids: [UUID], delta: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return delta > 0 ? ids.first : ids.last
        }
        return ids[min(max(0, index + delta), ids.count - 1)]
    }
}

/// The history as a panel in the player's right rail: what you have
/// watched, newest first, three columns — the item, when, and where
/// you stopped. A click or ↑ ↓ in the History zone loads that item in
/// this player, so the list is a way to walk back through what you
/// watched without leaving the window. Toggled like the other panels.
struct HistoryPanel: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").modifier(Theme.sectionLabel())
                Spacer()
                Text(model.historyRows.isEmpty ? "" : "\(model.historyRows.count)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                ZoneBadge(zone: .history)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if model.historyRows.isEmpty {
                Text("Nothing watched yet.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.historyRows) { row($0) }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: model.historySelectionID) { _, id in
                        if let id { withAnimation(nil) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Item").modifier(Theme.sectionLabel())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Watched").modifier(Theme.sectionLabel())
                .frame(width: 74, alignment: .leading)
            Text("Stopped").modifier(Theme.sectionLabel())
                .frame(width: 64, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func row(_ item: MediaItem) -> some View {
        let selected = item.id == model.historySelectionID
        let playing = item.id == model.item?.id
        return Button {
            model.selectHistoryRow(item.id)
        } label: {
            HStack(spacing: 0) {
                Text(item.fileName)
                    .font(Theme.ui(11.5, playing ? .semibold : .regular))
                    .foregroundStyle(playing ? Theme.Accent.amber : Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.lastWatchedAt.map(WatchedView.relative) ?? "—")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                    .frame(width: 74, alignment: .leading)
                stopped(item)
                    .frame(width: 64, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(selected ? Theme.Surface.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
        .help(item.relativePath)
    }

    @ViewBuilder
    private func stopped(_ item: MediaItem) -> some View {
        if item.completed {
            Text("done")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Status.green)
        } else if let resume = item.resumePositionSeconds {
            Text(WatchedView.timecode(resume))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Accent.amber)
        } else {
            Text("start")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Text.disabled)
        }
    }
}
