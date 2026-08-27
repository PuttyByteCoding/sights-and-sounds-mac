import SwiftUI
import SightsAndSoundsKit

/// The tag editing panel beside the player — the tagging surface, kept
/// out of the player's own responsibilities. Checkbox categories render
/// as checkbox lists (Alt+1…9 toggles the first one); everything else is
/// pills + autocomplete. The default-focus category's field takes focus
/// when the panel opens or the item changes.
struct TagPanelView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // An empty vocabulary used to render the panel as a bare
                // strip that read as "nothing happened" — say why instead.
                if model.panelVocabulary.isEmpty {
                    Text("No tag categories in this library yet — create them from the browse toolbar's Categories button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.panelVocabulary) { entry in
                    if let label = entry.category.sectionLabel {
                        if label.isEmpty { Divider() } else {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                    }
                    if entry.category.displayAsCheckboxes {
                        CheckboxCategoryView(
                            entry: entry,
                            isAltTarget: entry.id == model.checkboxCategory?.id)
                    } else {
                        PillCategoryView(entry: entry)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 300)
        .background(.background.secondary)
    }
}

private struct CheckboxCategoryView: View {
    @Environment(PlayerModel.self) private var model
    let entry: CategoryTags
    let isAltTarget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.category.name)
                .font(.headline)
            ForEach(Array(entry.tags.enumerated()), id: \.element.id) { index, tag in
                Toggle(isOn: Binding(
                    get: { model.hasTag(tag.id) },
                    set: { _ in model.toggleTag(tag.id) }
                )) {
                    HStack(spacing: 4) {
                        Text(tag.name)
                        if isAltTarget && index < 9 {
                            Text("⌥\(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

private struct PillCategoryView: View {
    @Environment(PlayerModel.self) private var model
    let entry: CategoryTags
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var applied: [Tag] {
        model.itemTags.first { $0.id == entry.id }?.tags ?? []
    }

    private var suggestions: [Tag] {
        let query = draft.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let appliedIDs = Set(applied.map(\.id))
        return entry.tags
            .filter { !appliedIDs.contains($0.id) && $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.category.name)
                .font(.headline)

            if !applied.isEmpty {
                FlowLayoutLite(spacing: 4) {
                    ForEach(applied) { tag in
                        HStack(spacing: 2) {
                            Text(tag.name).font(.callout)
                            Button {
                                model.toggleTag(tag.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
            }

            TextField("Add \(entry.category.name)…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit {
                    let raw = draft.trimmingCharacters(in: .whitespaces)
                    guard !raw.isEmpty else { return }
                    model.addTag(named: raw, categoryID: entry.category.id)
                    draft = ""
                }

            ForEach(suggestions) { tag in
                Button {
                    model.toggleTag(tag.id)
                    draft = ""
                } label: {
                    Label(tag.name, systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: model.item?.id) {
            if entry.category.isDefaultFocus { fieldFocused = true }
        }
    }
}

/// Minimal wrapping layout for tag pills.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let slots = arrange(proposal: proposal, subviews: subviews).slots
        for (subview, slot) in zip(subviews, slots) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y),
                proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, slots: [CGPoint])
    {
        let maxWidth = proposal.width ?? 280
        var slots: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            slots.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), slots)
    }
}
