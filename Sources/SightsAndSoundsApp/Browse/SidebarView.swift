import SwiftUI
import SightsAndSoundsKit

struct SidebarView: View {
    @Environment(BrowseModel.self) private var model

    // Tag categories start collapsed — the sidebar shows names, the user
    // opens what they filter by. Keyed by category id so vocabulary
    // refreshes don't reset what's open; resets with the window.
    @State private var expandedCategories: Set<UUID> = []

    var body: some View {
        List {
            if !model.filter.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle") {
                    model.clearFilter()
                }
            }

            Section("Sources") {
                ForEach(model.sources) { source in
                    SourceRow(source: source)
                }
                Button("Add Source…", systemImage: "plus") { addSource() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Section("Folders") {
                FolderRow(name: "All Items", path: nil, count: nil, depth: 0)
                OutlineGroup(model.folderTree, children: \.childrenOrNil) { node in
                    FolderRow(name: node.name, path: node.path, count: node.subtreeCount, depth: 0)
                }
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
                    ForEach(entry.tags) { tag in
                        TagFilterRow(tag: tag)
                    }
                } header: {
                    HStack {
                        Text(entry.category.name)
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

    private func isExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedCategories.contains(id) },
            set: { open in
                if open { expandedCategories.insert(id) } else { expandedCategories.remove(id) }
            })
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
            }
        }
        .buttonStyle(.plain)
    }

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
