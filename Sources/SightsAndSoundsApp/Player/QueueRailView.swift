import SwiftUI
import SightsAndSoundsKit

/// The player's left rail: only the tags on this queue's items, counted
/// over the queue, and a click narrows what the strip and ←/→ walk. The
/// snapshot underneath is untouched — this is a view over it — and the
/// counts follow tag edits anywhere, so a tag applied in this player
/// appears here at once. No sources, folders, saved filters or status
/// rows: those define queues; they do not narrow one.
struct QueueRailView: View {
    @Environment(PlayerModel.self) private var model

    static let width: CGFloat = 200

    private var counts: [UUID: Int] { model.queue.tagCounts }

    /// Categories in panel order, each with the tags the queue holds, in
    /// name order. A category with nothing on the queue is absent.
    private var sections: [(category: TagCategory, tags: [Tag])] {
        model.panelVocabulary.compactMap { entry in
            let present = entry.tags
                .filter { (counts[$0.id] ?? 0) > 0 }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return present.isEmpty ? nil : (entry.category, present)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Narrow").modifier(Theme.sectionLabel())
                Text("\(model.queue.visible.count) of \(model.queue.items.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(
                        model.queue.requiredTagIDs.isEmpty ? Theme.Text.quaternary : Theme.Accent.amber)
                Spacer(minLength: 4)
                if !model.queue.requiredTagIDs.isEmpty {
                    Button("Clear") { model.queue.requiredTagIDs = [] }
                        .buttonStyle(.plain)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if sections.isEmpty {
                        Text("No tags on this queue.")
                            .font(Theme.ui(Theme.TypeScale.secondary))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    ForEach(sections, id: \.category.id) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.category.name)
                                .font(Theme.ui(10, .semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                                .padding(.bottom, 2)
                            ForEach(section.tags) { tag in
                                row(tag, hue: Theme.categoryHue(section.category.colorIndex))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Border.standard).frame(width: 1)
        }
    }

    private func row(_ tag: Tag, hue: Color) -> some View {
        let required = model.queue.requiredTagIDs.contains(tag.id)
        return Button {
            if required {
                model.queue.requiredTagIDs.remove(tag.id)
            } else {
                model.queue.requiredTagIDs.insert(tag.id)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(hue).frame(width: 6, height: 6)
                Text(tag.name)
                    .font(Theme.ui(Theme.TypeScale.secondary, required ? .semibold : .regular))
                    .foregroundStyle(required ? Theme.Text.onAmber : Theme.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(counts[tag.id] ?? 0)")
                    .font(Theme.mono(10))
                    .foregroundStyle(required ? Theme.Text.onAmber : Theme.Text.quaternary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(required ? Theme.Accent.amber : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(required ? "Required — click to stop narrowing by it" : "Narrow the queue to items with this tag")
    }
}
