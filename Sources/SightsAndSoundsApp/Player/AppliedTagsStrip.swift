import SwiftUI
import SightsAndSoundsKit

/// The item's tags, as pills, directly under the video.
///
/// The tag panel in the rail is where tagging happens: fields, history,
/// suggestions, one category at a time. This is where the answer to
/// "what is this tagged" lives, in one glance, without opening a panel.
/// Pills are the same pills a tile wears, in category order, each with
/// the sidebar's count after its name. Clicking one filters the browse
/// window by the tag — the sidebar row's cycle, optional first — and
/// right-clicking edits the tag, as on a tile. Taking a tag off the
/// item is the panel's job, and the right-click menu's. The strip is a
/// single wrapping row, and disappears when the item has no tags.
struct AppliedTagsStrip: View {
    @Environment(PlayerModel.self) private var model
    @Environment(BrowseModel.self) private var browse
    @State private var pending: TagAction?

    /// Every applied tag with its category's hue, in category order.
    private var pills: [(tag: Tag, category: TagCategory)] {
        model.itemTags.flatMap { group in group.tags.map { (tag: $0, category: group.category) } }
    }

    /// What a click on a pill does: the same step a click on the tag's
    /// sidebar row takes, so the two gestures can never disagree. The
    /// click used to take the tag OFF the item — one slip of the mouse
    /// under the video undid a tagging.
    static func filter(by tagID: UUID, in browse: BrowseModel) {
        browse.filter.cycle(.tag(tagID))
    }

    var body: some View {
        if !pills.isEmpty {
            FlowRow(spacing: 5) {
                ForEach(pills, id: \.tag.id) { pill in
                    let hue = Theme.categoryHue(pill.category.colorIndex)
                    let count = browse.tagCount(pill.tag.id)
                    let slot = browse.filter.slot(of: pill.tag.id)
                    Button {
                        Self.filter(by: pill.tag.id, in: browse)
                    } label: {
                        TagPillLabel.text(pill.tag.name, count: count, countColor: hue.opacity(0.65))
                            .font(Theme.ui(10, .semibold))
                            .foregroundStyle(hue)
                            .lineLimit(1)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .background { Capsule().fill(hue.opacity(slot == nil ? 0.12 : 0.28)) }
                            .overlay { Capsule().stroke(hue.opacity(slot == nil ? 0.2 : 0.6), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .help(Self.help(category: pill.category.name, tag: pill.tag.name, count: count, slot: slot))
                    .accessibilityLabel("\(pill.tag.name), \(pill.category.name), \(count) items")
                    .accessibilityHint("Filters the library by the tag")
                    .contextMenu {
                        TagActionButtons(
                            tag: pill.tag, service: model.service, libraryID: model.libraryID,
                            pending: $pending,
                            removal: TagRemoval(
                                label: TagRemoval.label(for: model.item?.kind ?? .video)
                            ) { model.toggleTag(pill.tag.id) },
                            itemID: model.item?.id)
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
                $pending, service: model.service, libraryID: model.libraryID,
                categories: model.itemTags.map(\.category),
                onChange: { model.refreshTagging() })
        }
    }

    static func help(category: String, tag: String, count: Int, slot: MediaFilter.TagSlot?) -> String {
        let state = slot.map { " Filtering: \($0.menuTitle.lowercased())." } ?? ""
        return "\(category): \(tag) — \(count) item\(count == 1 ? "" : "s").\(state) Click cycles the filter through optional, required and excluded; right-click to edit or remove the tag."
    }
}
