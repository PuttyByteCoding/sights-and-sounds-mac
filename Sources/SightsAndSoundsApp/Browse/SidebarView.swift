import SwiftUI
import SightsAndSoundsKit

struct SidebarView: View {
    @Environment(BrowseModel.self) private var model

    // Tag categories start collapsed — the sidebar shows names, the user
    // opens what they filter by. Keyed by category id so vocabulary
    // refreshes don't reset what's open; resets with the window.
    @State private var expandedCategories: Set<UUID> = []
    // Folder trees, nested under their source rows, start collapsed too.
    @State private var expandedSources: Set<UUID> = []
    // Per-category tag-narrowing queries (view-only — never the media
    // filter). Keyed by category id, same lifetime as the sets above.
    @State private var tagQueries: [UUID: String] = [:]

    var body: some View {
        List {
            if !model.filter.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle") {
                    model.clearFilter()
                }
            }

            Section("Sources") {
                FolderRow(name: "All Items", path: nil, count: nil, depth: 0)
                ForEach(model.sources) { source in
                    // Each source discloses its own folder tree, closed
                    // by default — the sidebar opens showing just rows.
                    DisclosureGroup(isExpanded: isExpandedSource(source.id)) {
                        OutlineGroup(
                            model.folderTrees[source.id] ?? [], children: \.childrenOrNil
                        ) { node in
                            FolderRow(
                                name: node.name, path: node.path,
                                count: node.subtreeCount, depth: 0)
                        }
                    } label: {
                        // Sidebar convention: clicking a collapsible
                        // header's name toggles it — the chevron is a
                        // small target. Right-click (context menu) is
                        // untouched by the tap gesture.
                        SourceRow(source: source)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(source.id, in: &expandedSources) }
                    }
                }
                Button("Add Source…", systemImage: "plus") { addSource() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.vocabulary) { entry in
                // A section label above a category: "" draws a plain divider,
                // text draws a labeled header (old browse-panel semantics).
                if let label = entry.category.sectionLabel {
                    if label.isEmpty { Divider() } else {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
                Section(isExpanded: isExpanded(entry.category.id)) {
                    if entry.tags.count > 8 {
                        TagQueryField(text: query(for: entry.category.id))
                    }
                    ForEach(visibleTags(of: entry)) { tag in
                        TagFilterRow(tag: tag)
                    }
                } header: {
                    HStack {
                        Text("\(entry.category.name) (\(entry.tags.count))")
                        Spacer()
                        // A collapsed category must still signal live
                        // selections — a filter can't hide invisibly.
                        if !expandedCategories.contains(entry.category.id) {
                            let active = entry.tags.count { model.filter.slot(of: $0.id) != nil }
                            if active > 0 {
                                Text("\(active)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    // Sidebar convention: clicking a collapsible header's
                    // name toggles it — the whole header row, not just
                    // the chevron.
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(entry.category.id, in: &expandedCategories) }
                }
            }

            Section("Status") {
                ForEach(StatusFlag.allCases, id: \.self) { flag in
                    StatusRow(flag: flag)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func isExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedCategories.contains(id) },
            set: { open in
                if open { expandedCategories.insert(id) } else { expandedCategories.remove(id) }
            })
    }

    private func isExpandedSource(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(id) },
            set: { open in
                if open { expandedSources.insert(id) } else { expandedSources.remove(id) }
            })
    }

    private func query(for id: UUID) -> Binding<String> {
        Binding(
            get: { tagQueries[id, default: ""] },
            set: { tagQueries[id] = $0 })
    }

    /// The category's tags under its narrowing query. Name and alias
    /// match case-insensitively; a tag with an ACTIVE filter slot always
    /// stays visible, so a selection can never hide behind the query.
    private func visibleTags(of entry: CategoryTags) -> [Tag] {
        let query = tagQueries[entry.category.id, default: ""]
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entry.tags }
        return entry.tags.filter { tag in
            model.filter.slot(of: tag.id) != nil
                || tag.name.localizedCaseInsensitiveContains(query)
                || (model.tagAliases[tag.id] ?? [])
                    .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// The narrowing field at the top of an expanded category — filters
/// which tag rows are SHOWN, never the media query itself.
private struct TagQueryField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Filter tags", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SourceRow: View {
    @Environment(BrowseModel.self) private var model
    let source: Source

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(source.name)
                .foregroundStyle(source.enabled ? .primary : .secondary)
            Spacer()
            if let status = model.importStatus[source.id] {
                Text(status)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tint)
            } else if !model.onlineSourceIDs.contains(source.id) && source.enabled {
                Text("offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Import New Files") { model.importSource(source) }
                .disabled(!source.enabled
                    || !model.onlineSourceIDs.contains(source.id)
                    || model.importStatus[source.id] != nil)
            Button(source.enabled ? "Disable" : "Enable") {
                model.setSourceEnabled(source, !source.enabled)
            }
        }
        .help(source.rootPath)
    }

    private var statusColor: Color {
        if !source.enabled { return .gray }
        return model.onlineSourceIDs.contains(source.id) ? .green : .orange
    }
}

private struct FolderRow: View {
    @Environment(BrowseModel.self) private var model
    let name: String
    let path: String?
    let count: Int?
    let depth: Int

    var body: some View {
        Button {
            model.selectFolder(path)
        } label: {
            HStack {
                Image(systemName: path == nil ? "square.grid.2x2" : "folder")
                Text(name)
                Spacer()
                if let count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
        .fontWeight(model.selectedFolderPath == path ? .semibold : .regular)
    }
}

private struct TagFilterRow: View {
    @Environment(BrowseModel.self) private var model
    let tag: Tag

    var body: some View {
        @Bindable var model = model
        Button {
            model.filter.cycleTag(tag.id)
        } label: {
            HStack {
                slotIcon
                Text(tag.name)
                if tag.hiddenByDefault {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Items carrying the tag, under the listing baseline —
                // zero renders dimmed, not hidden: "exists but unused
                // for this kind" is exactly the information (#96).
                let count = model.tagItemCounts[tag.id] ?? 0
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(count == 0 ? .tertiary : .secondary)
            }
        }
        .buttonStyle(.plain)
        // Edit in place — the Categories window stays the bulk editor;
        // a tag you can see shouldn't need a trip there (#108).
        .contextMenu {
            Button("Edit Tag…") { showEditor = true }
        }
        .popover(isPresented: $showEditor, arrowEdge: .trailing) {
            TagEditorView(tag: tag)
        }
    }

    @State private var showEditor = false

    @ViewBuilder private var slotIcon: some View {
        switch model.filter.slot(of: tag.id) {
        case .required:
            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
        case .optional:
            Image(systemName: "circle.dotted").foregroundStyle(.blue)
        case .excluded:
            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
        case nil:
            Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}

private struct StatusRow: View {
    @Environment(BrowseModel.self) private var model
    let flag: StatusFlag

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: Binding(
            get: { model.filter.required.contains(.status(flag)) },
            set: { _ in model.filter.toggleStatus(flag) }
        )) {
            Text(label)
        }
        .toggleStyle(.checkbox)
    }

    private var label: String {
        switch flag {
        case .needsReview: "Needs Review"
        case .playbackIssue: "Playback Issue"
        case .markedForDeletion: "Marked for Deletion"
        case .favorite: "Favorite"
        case .clip: "Clip (any)"
        case .embedded: "Embedded Clip"
        case .exported: "Exported Clip"
        case .edited: "Edited"
        }
    }
}

extension SidebarView {
    fileprivate func addSource() {
        let panel = NSOpenPanel()
        panel.title = "Add Source Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Add Source"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addSource(at: url)
    }
}

extension FolderNode {
    /// OutlineGroup wants nil for leaves.
    var childrenOrNil: [FolderNode]? { children.isEmpty ? nil : children }
}
