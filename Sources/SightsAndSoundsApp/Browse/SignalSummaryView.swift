import SwiftUI
import SightsAndSoundsKit

/// What the Media Signal sweep concluded about an item, beside the numbers
/// the Review window already compares. Two files of one recording often
/// differ in exactly this: one is the capture and the other is that
/// capture scaled up, and the bigger one is not the better one.
///
/// Origins are opinions and are worded as such; hovering a line lists the
/// readings behind it.
struct SignalSummaryView: View {
    @Environment(BrowseModel.self) private var model
    let item: MediaItem

    @State private var summary: SignalSummary?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary, !summary.isEmpty {
                ForEach(summary.origins) { line(for: $0, emphasized: true) }
                ForEach(summary.history) { line(for: $0, emphasized: false) }
            } else if loaded {
                Text("Not examined yet. Run Media Signal in Background Tasks.")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .task(id: item.id) { await load() }
    }

    private func line(for line: SignalSummary.Line, emphasized: Bool) -> some View {
        HStack {
            Text(line.phrase)
                .font(Theme.ui(10.5, emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? Theme.Text.secondary : Theme.Text.disabled)
                .lineLimit(1)
            Spacer()
            if !line.isFact, line.category != "Unknown" {
                Text(String(format: "%.0f%%", line.confidence * 100))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .help(line.evidence.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(line.evidence.joined(separator: ". "))
    }

    private func load() async {
        let library = model.library
        let item = item
        let found = await Task.detached(priority: .utility) {
            try? library.signalSummary(for: item)
        }.value
        summary = found
        loaded = true
    }
}
