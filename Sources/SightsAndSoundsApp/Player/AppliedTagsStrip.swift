import SwiftUI
import SightsAndSoundsKit

/// The item's tags, as pills, directly under the video.
///
/// The tag panel in the rail is where tagging happens: fields, history,
/// suggestions, one category at a time. This is where the answer to
/// "what is this tagged" lives, in one glance, without opening a panel.
/// Pills are the same pills a tile wears, in category order. Clicking one
/// removes it; right-clicking edits the tag, as on a tile. The strip is a
/// single wrapping row, and disappears when the item has no tags.
struct AppliedTagsStrip: View {
    @Environment(PlayerModel.self) private var model
    @State private var pending: TagAction?

    /// Every applied tag with its category's hue, in category order.
    private var pills: [(tag: Tag, category: TagCategory)] {
        model.itemTags.flatMap { group in group.tags.map { (tag: $0, category: group.category) } }
    }

    var body: some View {
        if !pills.isEmpty {
            FlowRow(spacing: 5) {
                ForEach(pills, id: \.tag.id) { pill in
                    let hue = Theme.categoryHue(pill.category.colorIndex)
                    Button {
                        model.toggleTag(pill.tag.id)
                    } label: {
                        Text(pill.tag.name)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(hue)
                            .lineLimit(1)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .background { Capsule().fill(hue.opacity(0.12)) }
                            .overlay { Capsule().stroke(hue.opacity(0.2), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .help("\(pill.category.name): \(pill.tag.name). Click to remove.")
                    .accessibilityLabel("\(pill.tag.name), \(pill.category.name)")
                    .accessibilityHint("Removes the tag")
                    .contextMenu {
                        TagActionButtons(
                            tag: pill.tag, library: model.library, libraryID: model.libraryID,
                            pending: $pending, itemID: model.item?.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }
            .tagActions(
                $pending, library: model.library, libraryID: model.libraryID,
                categories: model.itemTags.map(\.category),
                onChange: { model.refreshTagging() })
        }
    }
}
