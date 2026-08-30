import SwiftUI
import SightsAndSoundsKit

/// Authoring the library's vocabulary: what exists, what it is called,
/// and what it writes into files.
///
/// Three panes, one job each — the sidebar is what exists in its order,
/// the table is the tags with the numbers that make a vocabulary
/// judgeable, and the inspector configures whatever is selected. The
/// inspector is always present so a click never costs a sheet.
///
/// Every write goes through the kit's single write path (normalization,
/// single-select enforcement, cascades).
struct CategoryManagerView: View {
    @Environment(BrowseModel.self) private var model

    /// What the centre and the inspector are showing. Item fields are a
    /// peer of the categories, not a mode: the schema says a field
    /// attaches to a category's tags or to media items, never both.
    enum Selection: Hashable {
        case category(UUID)
        case itemFields
    }

    @State private var categories: [TagCategory] = []
    @State private var itemFields: [FieldDefinition] = []
    @State private var selection: Selection?
    @State private var tags: [Tag] = []
    @State private var aliases: [UUID: [String]] = [:]
    @State private var usage: [UUID: Int] = [:]
    @State private var tagFields: [FieldDefinition] = []
    @State private var selectedTagID: UUID?
    @State private var errorText: String?

    @State private var filter = ""
    @State private var similarOnly = false
    @State private var sortSpec: [TagSort] = [TagSort(column: .name, ascending: true)]
    @State private var mergeMode = false
    @State private var mergePicks: Set<UUID> = []
    @State private var mergeTargetIsNew = false
    @State private var mergeNewName = ""
    @State private var mergeTargetID: UUID?
    @State private var showPaste = false
    @State private var inspectorTab: InspectorTab = .category

    enum InspectorTab: String, CaseIterable { case category = "Category", tag = "Tag" }

    private var selectedCategory: TagCategory? {
        guard case .category(let id) = selection else { return nil }
        return categories.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.Border.standard).frame(width: 1)
            centre
            Rectangle().fill(Theme.Border.standard).frame(width: 1)
            inspector
        }
        .frame(minWidth: 980, minHeight: 560)
        .background(Theme.Surface.content)
        .onAppear { reload() }
        .sheet(isPresented: $showPaste) {
            if let category = selectedCategory {
                PasteTagListSheet(category: category, library: model.library) {
                    reloadTags()
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Categories").modifier(Theme.sectionLabel())
                Spacer()
                Button {
                    createCategory()
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .buttonStyle(.plain)
                .help("New category")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(categories) { category in
                        categoryRow(category)
                    }
                }
                .padding(.bottom, 8)
            }

            // Item fields are a peer entry, divided off: they belong to
            // the library rather than to any category.
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            Button {
                selection = .itemFields
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Media Item Fields")
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.Text.primary)
                        Text("scope mediaItem · applies to every item in the library")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.Text.disabled)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(itemFields.count)")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(selection == .itemFields ? Theme.Surface.selectedRow : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let errorText {
                Text(errorText)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Status.red)
                    .padding(10)
            }
        }
        .frame(width: 246)
        .background(Theme.Surface.raised)
    }

    private func categoryRow(_ category: TagCategory) -> some View {
        let selected = selection == .category(category.id)
        return Button {
            selection = .category(category.id)
            inspectorTab = .category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.Text.disabled)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.categoryHue(category.colorIndex))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(category.name)
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        if category.hiddenFromBrowse {
                            ThemeBadge(
                                text: "hidden", fill: Theme.Surface.iconTile,
                                foreground: Theme.Text.disabled)
                        }
                    }
                    Text(summary(of: category))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Text.disabled)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(selected ? Theme.Surface.selectedRow : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Theme.Accent.amber)
                        .frame(width: Theme.Border.selectionInsetWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move Up") { move(category, by: -1) }
            Button("Move Down") { move(category, by: 1) }
        }
    }

    private func summary(of category: TagCategory) -> String {
        var parts: [String] = []
        if case .category(let id) = selection, id == category.id {
            parts.append("\(tags.count) tags")
        }
        parts.append(category.allowMultiple ? "multiple" : "single")
        if category.displayStyle != .search {
            parts.append(category.displayStyle.displayName.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Centre

    @ViewBuilder private var centre: some View {
        VStack(spacing: 0) {
            switch selection {
            case .category(let id):
                if let category = categories.first(where: { $0.id == id }) {
                    TagTableHeader(
                        category: category,
                        tagCount: tags.count,
                        usageTotal: usage.values.reduce(0, +),
                        filter: $filter,
                        similarOnly: $similarOnly,
                        mergeMode: $mergeMode,
                        onPaste: { showPaste = true },
                        onAddTag: { addTag() })
                    TagTable(
                        rows: visibleRows,
                        aliases: aliases,
                        usage: usage,
                        similarOnly: similarOnly,
                        sortSpec: $sortSpec,
                        mergeMode: mergeMode,
                        picks: $mergePicks,
                        selectedTagID: $selectedTagID,
                        onSelect: { tag in
                            selectedTagID = tag.id
                            inspectorTab = .tag
                        },
                        onToggleFavorite: { tag in
                            try? model.library.setTagFavorite(tag.id, !tag.isFavorite)
                            reloadTags()
                        },
                        onHide: { tag in
                            try? model.library.setTagHidden(tag.id, !tag.hiddenByDefault)
                            reloadTags()
                        },
                        onDelete: { tag in
                            try? model.library.deleteTag(tag.id)
                            reloadTags()
                        })
                    if mergeMode {
                        MergeBar(
                            picks: mergePicks,
                            tags: tags,
                            targetIsNew: $mergeTargetIsNew,
                            targetID: $mergeTargetID,
                            newName: $mergeNewName,
                            onMerge: { performMerge(in: category) },
                            onCancel: {
                                mergeMode = false
                                mergePicks = []
                            })
                    }
                }
            case .itemFields:
                FieldEditor(
                    title: "Media Item Fields",
                    subtitle: "scope mediaItem · applies to every item in the library",
                    fields: itemFields,
                    library: model.library,
                    scope: .mediaItem,
                    categoryID: nil,
                    onChange: { reloadItemFields() })
            case nil:
                VStack(spacing: 6) {
                    Text("No category selected")
                        .font(Theme.ui(15, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("Select a category, or create one.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The rows the table draws: filtered, then clustered when Similar
    /// only is on, then sorted.
    private var visibleRows: [TagTableRow] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let filtered = tags.filter { tag in
            guard !query.isEmpty else { return true }
            return tag.name.localizedCaseInsensitiveContains(query)
                || (aliases[tag.id] ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        guard similarOnly else {
            return sorted(filtered).map { TagTableRow(tag: $0) }
        }
        // Clusters of two or more, most-used first, each under a header
        // naming the winner — this is the entire reason the window
        // exists for a migrated library.
        let clusters = TagSimilarity.clusters(
            filtered, name: \.name, uses: { usage[$0.id] ?? 0 })
        return clusters.flatMap { cluster -> [TagTableRow] in
            let header = TagTableRow(
                clusterHeader: "\(cluster.count) variants · \(cluster[0].name)")
            return [header] + cluster.map { TagTableRow(tag: $0) }
        }
    }

    private func sorted(_ rows: [Tag]) -> [Tag] {
        rows.sorted { left, right in
            for sort in sortSpec {
                let ordered: Bool?
                switch sort.column {
                case .name:
                    let comparison = left.name.localizedStandardCompare(right.name)
                    ordered = comparison == .orderedSame ? nil : (comparison == .orderedAscending)
                case .uses:
                    let l = usage[left.id] ?? 0, r = usage[right.id] ?? 0
                    ordered = l == r ? nil : (l < r)
                case .favorite:
                    ordered = left.isFavorite == right.isFavorite ? nil : right.isFavorite
                }
                if let ordered { return sort.ascending ? ordered : !ordered }
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    // MARK: - Inspector

    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            if case .itemFields = selection {
                VStack(spacing: 6) {
                    Text("Fields belong to the library")
                        .font(Theme.ui(12.5, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("A media-item field applies to every item; there is nothing per-category to configure.")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxHeight: .infinity)
            } else if let category = selectedCategory {
                Picker("", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
                switch inspectorTab {
                case .category:
                    CategoryInspector(
                        category: category,
                        tagCount: tags.count,
                        fields: tagFields,
                        library: model.library,
                        onChange: { save($0) },
                        onFieldsChange: { reloadTagFields() },
                        onDelete: {
                            try? model.library.deleteCategory(category.id)
                            selection = nil
                            reload()
                        })
                        // Identity must come from the PARENT's selection:
                        // the inspector copies the category into @State,
                        // and @State only reseeds on an identity change.
                        // An .id inside the inspector read its own stale
                        // state — every category showed (and EDITED) the
                        // first one.
                        .id(category.id)
                case .tag:
                    if let tag = tags.first(where: { $0.id == selectedTagID }) {
                        TagInspector(
                            tag: tag,
                            category: category,
                            uses: usage[tag.id] ?? 0,
                            aliases: aliases[tag.id] ?? [],
                            siblings: tags.filter { $0.id != tag.id },
                            fields: tagFields,
                            library: model.library,
                            onChange: { reloadTags() })
                            .id(tag.id)
                    } else {
                        Text("Select a tag to configure it.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.disabled)
                            .padding(20)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 326)
        .background(Theme.Surface.raised)
    }

    // MARK: - Loading
    //
    // Fetches run off the main actor; the generations drop any result a
    // newer request has superseded (the PR #38 pattern), so fast clicks
    // through big categories never publish stale rows or block the UI.

    @State private var categoryGeneration = 0
    @State private var tagGeneration = 0

    private func reload() {
        categoryGeneration += 1
        let generation = categoryGeneration
        let library = model.library
        Task {
            do {
                let fetched = try await library.writer.read {
                    try TagCategory.order(sql: "sortOrder, name").fetchAll($0)
                }
                guard generation == categoryGeneration else { return }
                categories = fetched
                if selection == nil, let first = categories.first {
                    selection = .category(first.id)
                }
                reloadTags()
                reloadItemFields()
            } catch { errorText = "\(error)" }
        }
    }

    private func reloadCategoriesOnly() {
        categoryGeneration += 1
        let generation = categoryGeneration
        let library = model.library
        Task {
            do {
                let fetched = try await library.writer.read {
                    try TagCategory.order(sql: "sortOrder, name").fetchAll($0)
                }
                guard generation == categoryGeneration else { return }
                categories = fetched
            } catch { errorText = "\(error)" }
        }
    }

    private func reloadTags() {
        guard case .category(let categoryID) = selection else {
            tags = []
            return
        }
        tagGeneration += 1
        let generation = tagGeneration
        let library = model.library
        Task {
            do {
                let fetched = try await library.writer.read {
                    try Tag.filter(sql: "tagCategoryID = ?", arguments: [categoryID])
                        .order(sql: "sortOrder, name").fetchAll($0)
                }
                let aliasRows = try await library.writer.read { try TagAlias.fetchAll($0) }
                // One grouped query, never a count per row.
                let counts = try library.tagUsageCounts(inCategory: categoryID)
                guard generation == tagGeneration else { return }
                tags = fetched
                aliases = Dictionary(grouping: aliasRows, by: \.tagID)
                    .mapValues { $0.map(\.alias).sorted() }
                usage = counts
                if let selectedTagID, !fetched.contains(where: { $0.id == selectedTagID }) {
                    self.selectedTagID = nil
                }
                reloadTagFields()
            } catch { errorText = "\(error)" }
        }
    }

    private func reloadTagFields() {
        guard case .category(let categoryID) = selection else {
            tagFields = []
            return
        }
        tagFields = (try? model.library.fields(scope: .tag, categoryID: categoryID)) ?? []
    }

    private func reloadItemFields() {
        itemFields = (try? model.library.fields(scope: .mediaItem)) ?? []
    }

    // MARK: - Writes

    private func save(_ category: TagCategory) {
        do {
            try model.library.updateCategory(category)
            errorText = nil
            // Narrow update: patch the edited row in place so the click
            // settles instantly, then refresh the (small) category table
            // in the background. Tags are untouched by a config edit.
            if let index = categories.firstIndex(where: { $0.id == category.id }) {
                categories[index] = category
            }
            reloadCategoriesOnly()
        } catch { errorText = "\(error)" }
    }

    private func createCategory() {
        do {
            let order = (categories.map(\.sortOrder).max() ?? 0) + 10
            let category = TagCategory(name: "New Category", sortOrder: order)
            try model.library.createCategory(category)
            reload()
            selection = .category(category.id)
            inspectorTab = .category
        } catch { errorText = "\(error)" }
    }

    /// Reordering writes every row's position once, rather than saving
    /// each moved category on its own.
    private func move(_ category: TagCategory, by delta: Int) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        let target = index + delta
        guard categories.indices.contains(target) else { return }
        var ordered = categories
        ordered.swapAt(index, target)
        do {
            try model.library.setCategoryOrder(ordered.map(\.id))
            categories = ordered
            reloadCategoriesOnly()
        } catch { errorText = "\(error)" }
    }

    private func addTag() {
        guard let category = selectedCategory else { return }
        do {
            let tag = try model.library.ensureTag(named: "New tag", inCategory: category.id)
            reloadTags()
            selectedTagID = tag.id
            inspectorTab = .tag
        } catch { errorText = "\(error)" }
    }

    private func performMerge(in category: TagCategory) {
        let sources = Array(mergePicks)
        guard sources.count > 1 || (mergeTargetIsNew && !sources.isEmpty) else { return }
        do {
            let target: LibraryDatabase.MergeTarget = mergeTargetIsNew
                ? .newTag(named: mergeNewName)
                : .existing(mergeTargetID ?? sources[0])
            try model.library.mergeTags(sources, into: target, keepNamesAsAliases: true)
            errorText = "\(sources.count) tags merged — names kept as aliases"
            mergeMode = false
            mergePicks = []
            mergeNewName = ""
            mergeTargetID = nil
            mergeTargetIsNew = false
            reloadTags()
            model.refreshAll()
        } catch { errorText = "\(error)" }
    }
}

// MARK: - Table model

struct TagSort: Equatable {
    enum Column: String, Equatable { case name, uses, favorite }
    var column: Column
    var ascending: Bool
}

/// A table row: a tag, or the header of a similarity cluster.
struct TagTableRow: Identifiable {
    var tag: Tag?
    var clusterHeader: String?

    init(tag: Tag) {
        self.tag = tag
        self.clusterHeader = nil
    }

    init(clusterHeader: String) {
        self.tag = nil
        self.clusterHeader = clusterHeader
    }

    var id: String { tag.map { $0.id.uuidString } ?? "header:\(clusterHeader ?? "")" }
}
