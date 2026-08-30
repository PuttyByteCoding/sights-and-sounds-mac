import SwiftUI
import SightsAndSoundsKit

/// Configuration for the selected category: what it is called, how it
/// behaves, how names are normalized, what it writes into files, and the
/// fields its tags carry.
struct CategoryInspector: View {
    @State var category: TagCategory
    let tagCount: Int
    let fields: [FieldDefinition]
    let library: LibraryDatabase
    let onChange: (TagCategory) -> Void
    let onFieldsChange: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Name") {
                    TextField("Name", text: $category.name)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12.5))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                        .onSubmit { onChange(category) }
                }

                section("Behaviour") {
                    toggleRow(
                        "Allow multiple per item", isOn: bound(\.allowMultiple),
                        note: "Band: yes. Year: no — a new pick replaces the old.")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display style")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.secondary)
                        Picker("", selection: bound(\.displayStyle)) {
                            ForEach(TagDisplayStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Renders every tag as a toggle instead of autocomplete. Small fixed sets only.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    toggleRow(
                        "Hidden from browse filters", isOn: bound(\.hiddenFromBrowse),
                        note: "Still editable — just absent from the filter panel.")
                }

                section("Name formatting") {
                    Picker("", selection: bound(\.textFormat)) {
                        Text("As typed").tag(TextFormat.noFormatting)
                        Text("Title Case").tag(TextFormat.titleCase)
                        Text("lowercase").tag(TextFormat.allLowercase)
                        Text("UPPERCASE").tag(TextFormat.allUppercase)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    toggleRow(
                        "Separators to spaces", isOn: bound(\.separatorsToSpaces),
                        note: "Converts - . _ to spaces before formatting runs.")
                    // A live example beats a description of a rule.
                    HStack(spacing: 6) {
                        Text("\"dave-matthews-band\"")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.Text.disabled)
                        Text("→")
                            .font(Theme.ui(10))
                            .foregroundStyle(Theme.Text.disabled)
                        Text("\"\(preview)\"")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.Accent.amber)
                    }
                }

                section("Metadata write-back") {
                    toggleRow(
                        "Write this category's tags to files", isOn: bound(\.writebackEnabled),
                        note: nil)
                    Picker("", selection: writebackBinding) {
                        Text("Auto (custom field)").tag(String?.none)
                        ForEach(StandardFields.all, id: \.key) { field in
                            Text(field.key).tag(String?.some(field.key))
                        }
                    }
                    .labelsHidden()
                    .disabled(!category.writebackEnabled)
                    Text("Writes as \(resolvedFieldName)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("Blank writes an uppercased custom field. A standard key (ARTIST, DATE, PERFORMER) maps to the container's own tag.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Tag fields") {
                    Text("Attach to every tag in this category — Venue gets a City, Taper gets Equipment.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                    FieldList(
                        fields: fields, library: library, scope: .tag,
                        categoryID: category.id, onChange: onFieldsChange)
                }

                Button("Delete Category…") { confirmDelete = true }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .confirmationDialog(
                        "Delete \u{201C}\(category.name)\u{201D}?",
                        isPresented: $confirmDelete
                    ) {
                        Button("Delete", role: .destructive) { onDelete() }
                    } message: {
                        Text("Removes the category, its \(tagCount) tags, every tagging that used them, and any field values underneath. This cannot be undone from this window.")
                    }
            }
            .padding(14)
        }
    }

    private var preview: String {
        TagNameFormatter.format("dave-matthews-band", for: category)
    }

    private var resolvedFieldName: String {
        StandardFields.effectiveVorbisName(
            categoryName: category.name, writebackField: category.writebackField)
    }

    private var writebackBinding: Binding<String?> {
        Binding(
            get: { category.writebackField },
            set: { newValue in
                category.writebackField = newValue
                onChange(category)
            })
    }

    private func bound<T>(_ keyPath: WritableKeyPath<TagCategory, T>) -> Binding<T> {
        Binding(
            get: { category[keyPath: keyPath] },
            set: { newValue in
                category[keyPath: keyPath] = newValue
                onChange(category)
            })
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).modifier(Theme.sectionLabel())
            content()
        }
    }

    /// A checkbox with its one-line consequence underneath — the note is
    /// what makes a behaviour list readable without a manual.
    private func toggleRow(
        _ label: String, isOn: Binding<Bool>, note: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: isOn) {
                Text(label)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .toggleStyle(.checkbox)
            if let note {
                Text(note)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Configuration for one tag: its name, its aliases, its field values,
/// and the two ways it can stop existing.
struct TagInspector: View {
    let tag: Tag
    let category: TagCategory
    let uses: Int
    let aliases: [String]
    let siblings: [Tag]
    let fields: [FieldDefinition]
    let library: LibraryDatabase
    let onChange: () -> Void

    @State private var name: String = ""
    @State private var newAlias = ""
    @State private var values: [UUID: String] = [:]
    @State private var convertTarget: UUID?
    @State private var confirmDelete = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Name").modifier(Theme.sectionLabel())
                        Spacer()
                        Text("\(uses) uses")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12.5))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                        .onSubmit {
                            // Renaming onto an existing name is refused by
                            // the kit: merging is a deliberate operation,
                            // not a rename side effect.
                            do {
                                try library.renameTag(tag.id, to: name)
                                errorText = nil
                            } catch { errorText = "\(error)" }
                            onChange()
                        }
                }

                HStack(spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { tag.isFavorite },
                        set: { on in
                            try? library.setTagFavorite(tag.id, on)
                            onChange()
                        })
                    ) {
                        Text("Favourite").font(Theme.ui(12))
                    }
                    .toggleStyle(.checkbox)
                    Toggle(isOn: Binding(
                        get: { tag.hiddenByDefault },
                        set: { on in
                            try? library.setTagHidden(tag.id, on)
                            onChange()
                        })
                    ) {
                        Text("Hidden").font(Theme.ui(12))
                    }
                    .toggleStyle(.checkbox)
                }
                .foregroundStyle(Theme.Text.secondary)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Aliases").modifier(Theme.sectionLabel())
                        Text("match on search & import")
                            .font(Theme.ui(10))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    if !aliases.isEmpty {
                        FlowRow(spacing: 5) {
                            ForEach(aliases, id: \.self) { alias in
                                HStack(spacing: 4) {
                                    Text(alias)
                                        .font(Theme.ui(11))
                                        .foregroundStyle(Theme.Text.secondary)
                                    Button {
                                        try? library.removeAlias(alias, fromTag: tag.id)
                                        onChange()
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(Theme.ui(8))
                                            .foregroundStyle(Theme.Text.disabled)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(Capsule().fill(Theme.Surface.iconTile))
                            }
                        }
                    }
                    TextField("Add an alias", text: $newAlias)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                        .onSubmit {
                            try? library.addAlias(newAlias, toTag: tag.id)
                            newAlias = ""
                            onChange()
                        }
                }

                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Field values").modifier(Theme.sectionLabel())
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(field.name)
                                        .font(Theme.ui(11.5))
                                        .foregroundStyle(Theme.Text.tertiary)
                                    Text(field.dataType.rawValue)
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.Text.disabled)
                                        .padding(.vertical, 1)
                                        .padding(.horizontal, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                                .fill(Theme.Surface.iconTile))
                                }
                                TextField("", text: Binding(
                                    get: { values[field.id] ?? "" },
                                    set: { values[field.id] = $0 })
                                )
                                .textFieldStyle(.plain)
                                .font(Theme.ui(12))
                                .padding(.vertical, 5)
                                .padding(.horizontal, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                                        .fill(Theme.Surface.well)
                                        .stroke(Theme.Border.standard, lineWidth: 1))
                                .onSubmit {
                                    try? library.setFieldValue(
                                        values[field.id] ?? "", ofTag: tag.id, field: field)
                                    onChange()
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Instead of deleting").modifier(Theme.sectionLabel())
                    HStack(spacing: 6) {
                        Picker("", selection: $convertTarget) {
                            Text("Convert to alias of…").tag(UUID?.none)
                            ForEach(siblings) { sibling in
                                Text(sibling.name).tag(UUID?.some(sibling.id))
                            }
                        }
                        .labelsHidden()
                        Button("Convert") {
                            guard let convertTarget else { return }
                            do {
                                try library.convertTagToAlias(tag.id, of: convertTarget)
                                onChange()
                            } catch { errorText = "\(error)" }
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(convertTarget == nil)
                    }
                    Button("Delete Tag…") { confirmDelete = true }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .confirmationDialog(
                            "Delete \u{201C}\(tag.name)\u{201D}?", isPresented: $confirmDelete
                        ) {
                            Button("Delete", role: .destructive) {
                                try? library.deleteTag(tag.id)
                                onChange()
                            }
                        } message: {
                            Text("Removes the tag from \(uses) items. Consider Convert to alias instead — that keeps the taggings and folds the name into another tag.")
                        }
                }

                if let errorText {
                    Text(errorText)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Status.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
        .onAppear {
            name = tag.name
            values = (try? library.fieldValues(ofTag: tag.id)) ?? [:]
        }
    }
}

/// The fields of one scope, listed and edited in place.
struct FieldList: View {
    let fields: [FieldDefinition]
    let library: LibraryDatabase
    let scope: FieldScope
    let categoryID: UUID?
    let onChange: () -> Void

    @State private var newName = ""
    @State private var newType: FieldDataType = .text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                HStack(spacing: 8) {
                    Text(field.name)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.Text.secondary)
                    Text(field.dataType.rawValue)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Text.disabled)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .fill(Theme.Surface.iconTile))
                    if field.required {
                        Text("required")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    Spacer(minLength: 0)
                    Button {
                        try? library.deleteField(field.id)
                        onChange()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.ui(9))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this field and every value stored under it")
                }
            }
            HStack(spacing: 6) {
                TextField("New field", text: $newName)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(Theme.Border.standard, lineWidth: 1))
                Picker("", selection: $newType) {
                    ForEach(FieldDataType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Button("Add") { add() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Number fields also store a numeric value so sorting is numeric, and dates normalize to ISO 8601 — this is what makes ordering by a field possible at all.")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        let field = FieldDefinition(
            name: newName, dataType: newType, scope: scope,
            tagCategoryID: scope == .tag ? categoryID : nil,
            sortOrder: (fields.map(\.sortOrder).max() ?? 0) + 10)
        try? library.createField(field)
        newName = ""
        onChange()
    }
}

/// The media-item fields pane — the same editor, in the centre column,
/// because item fields have no category to be configured under.
struct FieldEditor: View {
    let title: String
    let subtitle: String
    let fields: [FieldDefinition]
    let library: LibraryDatabase
    let scope: FieldScope
    let categoryID: UUID?
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(subtitle)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            FieldList(
                fields: fields, library: library, scope: scope,
                categoryID: categoryID, onChange: onChange)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bulk creation: one name per line, normalized by the category's rule,
/// deduped against existing names AND aliases, with the counts shown
/// before anything is written.
struct PasteTagListSheet: View {
    let category: TagCategory
    let library: LibraryDatabase
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var existingNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste tag list into \(category.name)")
                    .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("One name per line. Names are normalized by this category's formatting rule, deduped against existing tags, and created in chunks.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            TextEditor(text: $text)
                .font(Theme.mono(12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Text("\(newNames.count) new")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Status.green)
                Text("\(duplicateCount) already exist")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.disabled)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Create \(newNames.count)") { create() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newNames.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(Theme.Surface.dialog)
        .onAppear { loadExisting() }
    }

    /// Normalized, deduped within the paste and against what exists.
    private var normalized: [String] {
        text.split(separator: "\n")
            .map { TagNameFormatter.format(String($0).trimmingCharacters(in: .whitespaces), for: category) }
            .filter { !$0.isEmpty }
    }

    private var newNames: [String] {
        var seen: Set<String> = []
        return normalized.filter { name in
            let key = name.lowercased()
            guard !existingNames.contains(key) else { return false }
            return seen.insert(key).inserted
        }
    }

    private var duplicateCount: Int { normalized.count - newNames.count }

    private func loadExisting() {
        // Names AND aliases: an alias is a name, so pasting one must not
        // create a rival spelling of the tag it already points at.
        existingNames = (try? library.writer.read { db -> Set<String> in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM tag WHERE tagCategoryID = ?", arguments: [category.id])
            let aliases = try String.fetchAll(
                db,
                sql: """
                SELECT tagAlias.alias FROM tagAlias \
                JOIN tag ON tag.id = tagAlias.tagID WHERE tag.tagCategoryID = ?
                """,
                arguments: [category.id])
            return Set((names + aliases).map { $0.lowercased() })
        }) ?? []
    }

    private func create() {
        for name in newNames {
            _ = try? library.ensureTag(named: name, inCategory: category.id)
        }
        onDone()
        dismiss()
    }
}
