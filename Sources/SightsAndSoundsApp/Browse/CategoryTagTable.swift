import SwiftUI
import SightsAndSoundsKit

/// The header above the tag table: what this category is, and the four
/// things you do to it.
struct TagTableHeader: View {
    let category: TagCategory
    let tagCount: Int
    let usageTotal: Int
    @Binding var filter: String
    @Binding var similarOnly: Bool
    @Binding var mergeMode: Bool
    let onPaste: () -> Void
    let onAddTag: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(category.name)
                    .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("\(tagCount) tags · \(usageTotal) taggings")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.disabled)
                Spacer()
            }
            HStack(spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                    TextField("Filter tags and aliases", text: $filter)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .frame(width: 220)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))

                ThemeSegmentedControl(
                    selection: $similarOnly,
                    options: [(false, "All"), (true, "Similar only")],
                    emphasis: .neutral)

                Spacer()

                Button(mergeMode ? "Cancel merge" : "Merge tags") { mergeMode.toggle() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Paste List…", action: onPaste)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("+ Tag", action: onAddTag)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }
}

/// The tags, with the numbers that make a vocabulary judgeable: a name
/// and an ellipsis menu is enough to fix a typo and nothing else.
///
/// The header row lives INSIDE the scroller as a pinned section header,
/// and both it and the rows share one column definition — a header
/// outside a scroller and rows inside it have different available widths,
/// which is how these columns come apart.
struct TagTable: View {
    let rows: [TagTableRow]
    let aliases: [UUID: [String]]
    let usage: [UUID: Int]
    let similarOnly: Bool
    @Binding var sortSpec: [TagSort]
    let mergeMode: Bool
    @Binding var picks: Set<UUID>
    @Binding var selectedTagID: UUID?
    let onSelect: (Tag) -> Void
    let onToggleFavorite: (Tag) -> Void
    let onHide: (Tag) -> Void
    let onDelete: (Tag) -> Void

    var body: some View {
        if rows.isEmpty {
            VStack(spacing: 6) {
                Text(similarOnly
                    ? "No near-duplicate names in this category."
                    : "No tags match that filter.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            if let header = row.clusterHeader {
                                Text(header)
                                    .modifier(Theme.sectionLabel(Theme.Accent.amber))
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let tag = row.tag {
                                tagRow(tag)
                            }
                        }
                    } header: {
                        headerRow
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            if mergeMode { Color.clear.frame(width: 30) }
            sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            Text("Aliases")
                .modifier(Theme.sectionLabel())
                .frame(width: 150, alignment: .leading)
            sortHeader("Uses", .uses).frame(width: 66, alignment: .trailing)
            sortHeader("★", .favorite).frame(width: 40, alignment: .center)
            Color.clear.frame(width: 34)
        }
        .padding(.horizontal, 16)
        .frame(height: 31)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    /// Click sorts; shift-click ADDS a secondary sort, and the header
    /// mark carries its position so a two-key sort is legible.
    private func sortHeader(_ label: String, _ column: TagSort.Column) -> some View {
        Button {
            let shift = NSEvent.modifierFlags.contains(.shift)
            if let index = sortSpec.firstIndex(where: { $0.column == column }) {
                sortSpec[index].ascending.toggle()
                if !shift { sortSpec = [sortSpec[index]] }
            } else if shift {
                sortSpec.append(TagSort(column: column, ascending: true))
            } else {
                sortSpec = [TagSort(column: column, ascending: true)]
            }
        } label: {
            HStack(spacing: 3) {
                Text(label).modifier(Theme.sectionLabel(
                    sortSpec.contains { $0.column == column }
                        ? Theme.Accent.amber : Theme.Text.quaternary))
                if let index = sortSpec.firstIndex(where: { $0.column == column }) {
                    Text(sortSpec[index].ascending ? "▲" : "▼")
                        .font(Theme.ui(7))
                        .foregroundStyle(Theme.Accent.amber)
                    if sortSpec.count > 1 {
                        Text("\(index + 1)")
                            .font(Theme.mono(8))
                            .foregroundStyle(Theme.Accent.amber)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to sort · shift-click to add a second sort")
    }

    private func tagRow(_ tag: Tag) -> some View {
        let selected = selectedTagID == tag.id
        return HStack(spacing: 0) {
            if mergeMode {
                Button {
                    if picks.contains(tag.id) { picks.remove(tag.id) } else { picks.insert(tag.id) }
                } label: {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .fill(picks.contains(tag.id) ? Theme.Accent.amber : .clear)
                        .stroke(
                            picks.contains(tag.id)
                                ? Theme.Accent.amber : Theme.Border.subtleButtonHover,
                            lineWidth: 1)
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .frame(width: 30, alignment: .leading)
            }
            HStack(spacing: 5) {
                Text(tag.name)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if tag.hiddenByDefault {
                    Image(systemName: "eye.slash")
                        .font(Theme.ui(9))
                        .foregroundStyle(Theme.Text.disabled)
                        .help("Hidden by default — items carrying it leave listings unless it is filtered on")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text((aliases[tag.id] ?? []).joined(separator: ", "))
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
                .help("match on search & import")
            Text("\(usage[tag.id] ?? 0)")
                .font(Theme.mono(11))
                .foregroundStyle(
                    (usage[tag.id] ?? 0) == 0 ? Theme.Text.zeroCount : Theme.Text.quaternary)
                .frame(width: 66, alignment: .trailing)
            Button {
                onToggleFavorite(tag)
            } label: {
                Text("★")
                    .font(Theme.ui(11))
                    .foregroundStyle(tag.isFavorite ? Theme.Accent.amber : Theme.Text.zeroCount)
            }
            .buttonStyle(.plain)
            .frame(width: 40, alignment: .center)
            Menu {
                Button(tag.hiddenByDefault ? "Unhide" : "Hide by default") { onHide(tag) }
                Button("Delete", role: .destructive) { onDelete(tag) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(selected ? Theme.Surface.selectedRow : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tag) }
    }
}

/// Merge mode's foot: what to pick, what is picked, and where it lands.
struct MergeBar: View {
    let picks: Set<UUID>
    let tags: [Tag]
    @Binding var targetIsNew: Bool
    @Binding var targetID: UUID?
    @Binding var newName: String
    let onMerge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick tags to merge, then a target — one of the picks, or a new tag the picks become aliases of.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
            HStack(spacing: 9) {
                Text("\(picks.count) picked")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Accent.amber)
                ThemeSegmentedControl(
                    selection: $targetIsNew,
                    options: [(false, "One of the picks"), (true, "A new tag")],
                    emphasis: .neutral)
                if targetIsNew {
                    TextField("New tag name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .frame(width: 200)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                } else {
                    Picker("", selection: $targetID) {
                        Text("—").tag(UUID?.none)
                        ForEach(pickedTags) { tag in
                            Text(tag.name).tag(UUID?.some(tag.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Merge", action: onMerge)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(picks.count < 2 && !(targetIsNew && !picks.isEmpty))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var pickedTags: [Tag] {
        tags.filter { picks.contains($0.id) }
    }
}
