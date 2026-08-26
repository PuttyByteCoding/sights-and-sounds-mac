import SwiftUI
import SightsAndSoundsKit

/// Vocabulary management: category configuration on the left, the selected
/// category's tags on the right. Every write goes through the kit's single
/// write path (normalization, focus exclusivity, cascades).
struct CategoryManagerView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var categories: [TagCategory] = []
    @State private var tags: [Tag] = []
    @State private var selectedID: UUID?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                categoryList
                    .frame(minWidth: 200, maxWidth: 260)
                if let category = categories.first(where: { $0.id == selectedID }) {
                    CategoryDetail(
                        category: category, tags: tags,
                        onChange: { updated in save(updated) },
                        onTagAction: { reloadTags() },
                        library: model.library,
                        errorText: $errorText)
                } else {
                    ContentUnavailableView(
                        "No Category Selected", systemImage: "tag",
                        description: Text("Select or create a category."))
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                Button("New Category", systemImage: "plus") { createCategory() }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Done") {
                    model.refreshAll()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { reload() }
    }

    private var categoryList: some View {
        List(selection: $selectedID) {
            ForEach(categories) { category in
                VStack(alignment: .leading) {
                    Text(category.name)
                    Text(summary(of: category))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(category.id)
            }
        }
        .onChange(of: selectedID) { reloadTags() }
    }

    private func summary(of category: TagCategory) -> String {
        var parts = [category.allowMultiple ? "multiple" : "single"]
        if category.displayAsCheckboxes { parts.append("checkboxes") }
        if category.isDefaultFocus { parts.append("focus") }
        if category.hiddenFromBrowse { parts.append("hidden") }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        do {
            categories = try model.library.writer.read {
                try TagCategory.order(sql: "sortOrder, name").fetchAll($0)
            }
            if selectedID == nil { selectedID = categories.first?.id }
            reloadTags()
        } catch { errorText = "\(error)" }
    }

    private func reloadTags() {
        guard let selectedID else { return }
        do {
            tags = try model.library.writer.read {
                try Tag.filter(sql: "tagCategoryID = ?", arguments: [selectedID])
                    .order(sql: "sortOrder, name").fetchAll($0)
            }
        } catch { errorText = "\(error)" }
    }

    private func save(_ category: TagCategory) {
        do {
            try model.library.updateCategory(category)
            errorText = nil
            reload()
        } catch { errorText = "\(error)" }
    }

    private func createCategory() {
        do {
            let order = (categories.map(\.sortOrder).max() ?? 0) + 10
            let category = TagCategory(name: "New Category", sortOrder: order)
            try model.library.createCategory(category)
            reload()
            selectedID = category.id
        } catch { errorText = "\(error)" }
    }
}

private struct CategoryDetail: View {
    @State var category: TagCategory
    let tags: [Tag]
    let onChange: (TagCategory) -> Void
    let onTagAction: () -> Void
    let library: LibraryDatabase
    @Binding var errorText: String?

    @State private var newTagName = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Configuration") {
                TextField("Name", text: $category.name)
                    .onSubmit { onChange(category) }
                Toggle("Allow multiple per item", isOn: bound(\.allowMultiple))
                Toggle("Display as checkboxes", isOn: bound(\.displayAsCheckboxes))
                Toggle("Default focus", isOn: bound(\.isDefaultFocus))
                Toggle("Hidden from browse filters", isOn: bound(\.hiddenFromBrowse))
                Picker("Text format", selection: bound(\.textFormat)) {
                    Text("As typed").tag(TextFormat.noFormatting)
                    Text("Title Case").tag(TextFormat.titleCase)
                    Text("lowercase").tag(TextFormat.allLowercase)
                    Text("UPPERCASE").tag(TextFormat.allUppercase)
                }
                Toggle("Separators to spaces (- . _)", isOn: bound(\.separatorsToSpaces))
            }

            Section("Tags (\(tags.count))") {
                ForEach(tags) { tag in
                    TagRow(tag: tag, library: library, errorText: $errorText, onAction: onTagAction)
                }
                HStack {
                    TextField("New tag…", text: $newTagName)
                        .onSubmit { addTag() }
                    Button("Add") { addTag() }
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                Button("Delete Category…", role: .destructive) { confirmDelete = true }
                    .confirmationDialog(
                        "Delete “\(category.name)” and its \(tags.count) tags? Item taggings and field values under it are removed too.",
                        isPresented: $confirmDelete
                    ) {
                        Button("Delete", role: .destructive) {
                            try? library.deleteCategory(category.id)
                            onTagAction()
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .id(category.id)
    }

    private func bound<T>(_ keyPath: WritableKeyPath<TagCategory, T>) -> Binding<T> {
        Binding(
            get: { category[keyPath: keyPath] },
            set: { newValue in
                category[keyPath: keyPath] = newValue
                onChange(category)
            })
    }

    private func addTag() {
        let raw = newTagName.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        do {
            _ = try library.ensureTag(named: raw, inCategory: category.id)
            newTagName = ""
            errorText = nil
            onTagAction()
        } catch { errorText = "\(error)" }
    }
}

private struct TagRow: View {
    let tag: Tag
    let library: LibraryDatabase
    @Binding var errorText: String?
    let onAction: () -> Void

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack {
            if renaming {
                TextField("Name", text: $draft)
                    .onSubmit {
                        do {
                            try library.renameTag(tag.id, to: draft)
                            errorText = nil
                        } catch { errorText = "\(error)" }
                        renaming = false
                        onAction()
                    }
            } else {
                Text(tag.name)
            }
            if tag.hiddenByDefault {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename") {
                    draft = tag.name
                    renaming = true
                }
                Button(tag.hiddenByDefault ? "Unhide" : "Hide by default") {
                    try? library.setTagHidden(tag.id, !tag.hiddenByDefault)
                    onAction()
                }
                Button("Delete", role: .destructive) {
                    try? library.deleteTag(tag.id)
                    onAction()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
    }
}
