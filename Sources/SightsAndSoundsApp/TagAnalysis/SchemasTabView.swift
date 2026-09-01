import SwiftUI
import SightsAndSoundsKit

/// Authoring the library's known JSON shapes — the third mode of the
/// Tag Analysis window. A schema is a named key list: which keys make a
/// payload recognisable, and which category each key's values belong
/// to. The fastest way in is pasting a sample payload and letting the
/// editor read the keys out of it.
@Observable
@MainActor
final class SchemasTabModel {
    let library: LibraryDatabase

    private(set) var schemas: [JsonSchemaDefinition] = []
    private(set) var categories: [TagCategory] = []
    private(set) var loadError: String?

    var selectedID: UUID?
    var draftName = ""
    var draftKeys: [SchemaKey] = []
    var sampleJSON = ""

    init(library: LibraryDatabase) {
        self.library = library
    }

    var selected: JsonSchemaDefinition? {
        schemas.first { $0.id == selectedID }
    }

    func reload() {
        do {
            schemas = try library.jsonSchemas()
            categories = (try? library.vocabulary().map(\.category)) ?? []
            loadError = nil
            if let selectedID, !schemas.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            loadError = "\(error)"
        }
    }

    func select(_ schema: JsonSchemaDefinition) {
        selectedID = schema.id
        draftName = schema.name
        draftKeys = schema.keys
        sampleJSON = ""
    }

    func startNew() {
        selectedID = nil
        draftName = ""
        draftKeys = []
        sampleJSON = ""
    }

    /// Read the keys out of a pasted sample — every distinct raw key the
    /// extractor finds, required by default, category unmapped. Keys the
    /// draft already lists are kept as-is: pasting a second sample adds,
    /// never resets.
    func seedFromSample() {
        let known = Set(draftKeys.map { KeyNormalizer.normalize($0.key) })
        var seen = known
        for leaf in JsonLeafExtractor.extract(sampleJSON) {
            guard let key = leaf.rawKey else { continue }
            let folded = KeyNormalizer.normalize(key)
            guard seen.insert(folded).inserted else { continue }
            draftKeys.append(SchemaKey(key: key, required: true))
        }
    }

    func save() {
        do {
            let saved = try library.saveJsonSchema(
                named: draftName,
                keys: draftKeys.filter {
                    !$0.key.trimmingCharacters(in: .whitespaces).isEmpty
                })
            reload()
            selectedID = saved.id
        } catch {
            loadError = "\(error)"
        }
    }

    func delete(_ schema: JsonSchemaDefinition) {
        do {
            try library.deleteJsonSchema(schema.id)
            if selectedID == schema.id { startNew() }
            reload()
        } catch {
            loadError = "\(error)"
        }
    }
}

struct SchemasTabView: View {
    let model: SchemasTabModel

    var body: some View {
        HSplitView {
            list.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            editor.frame(minWidth: 420)
        }
        .task { model.reload() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("A payload matches when every required key is present.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("+ Schema") { model.startNew() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            if model.schemas.isEmpty {
                VStack(spacing: 6) {
                    Text("No schemas yet")
                        .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                    Text("Paste a sample payload on the right and name the shape.")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.schemas) { schema in
                            row(schema)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Theme.Surface.content)
    }

    private func row(_ schema: JsonSchemaDefinition) -> some View {
        let active = schema.id == model.selectedID
        return Button {
            model.select(schema)
        } label: {
            HStack(spacing: 8) {
                Text(schema.name)
                    .font(Theme.ui(Theme.TypeScale.row, active ? .semibold : .regular))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 6)
                Text("\(schema.keys.count) keys · \(schema.keys.count(where: { $0.category != nil })) mapped")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(active ? Theme.Surface.selectedRow : Theme.Surface.raised)
                    .stroke(active ? Theme.Border.activeCard : Theme.Border.standard, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Schema") { model.delete(schema) }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.selectedID == nil ? "New schema" : "Edit schema")
                    .modifier(Theme.sectionLabel())

                TextField(
                    "Schema name — e.g. Show Notes",
                    text: Binding(get: { model.draftName }, set: { model.draftName = $0 }))
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(Theme.Border.standard, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample payload").modifier(Theme.sectionLabel())
                    TextEditor(text: Binding(
                        get: { model.sampleJSON }, set: { model.sampleJSON = $0 }))
                        .font(Theme.mono(11))
                        .scrollContentBackground(.hidden)
                        .frame(height: 96)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                    Button("Read Keys from Sample") { model.seedFromSample() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(!JsonLeafExtractor.isStructuredJSON(model.sampleJSON))
                    Text("Paste one real payload — the keys come out of it. Pasting another ADDS keys; it never resets what you have edited.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.quaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Keys").modifier(Theme.sectionLabel())
                        Spacer()
                        Button("+ Key") {
                            model.draftKeys.append(SchemaKey(key: "", required: false))
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                    if model.draftKeys.isEmpty {
                        Text("No keys yet — paste a sample above, or add them by hand.")
                            .font(Theme.ui(Theme.TypeScale.secondary))
                            .foregroundStyle(Theme.Text.quaternary)
                    }
                    ForEach(Array(model.draftKeys.enumerated()), id: \.offset) { index, key in
                        keyRow(index, key)
                    }
                }

                if let error = model.loadError {
                    Text(error)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Status.orange)
                }

                HStack {
                    if let selected = model.selected {
                        Button("Delete") { model.delete(selected) }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                    Spacer()
                    Button("Save Schema") { model.save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(
                            model.draftName.trimmingCharacters(in: .whitespaces).isEmpty
                                || model.draftKeys.allSatisfy {
                                    $0.key.trimmingCharacters(in: .whitespaces).isEmpty
                                })
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Surface.sidebar)
    }

    private func keyRow(_ index: Int, _ key: SchemaKey) -> some View {
        HStack(spacing: 8) {
            TextField(
                "key",
                text: Binding(
                    get: { model.draftKeys[safe: index]?.key ?? "" },
                    set: { if model.draftKeys.indices.contains(index) { model.draftKeys[index].key = $0 } }))
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .frame(width: 140)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))

            Toggle("required", isOn: Binding(
                get: { model.draftKeys[safe: index]?.required ?? false },
                set: { if model.draftKeys.indices.contains(index) { model.draftKeys[index].required = $0 } }))
                .toggleStyle(.checkbox)
                .font(Theme.ui(11))

            Picker("", selection: Binding(
                get: { model.draftKeys[safe: index]?.category },
                set: { if model.draftKeys.indices.contains(index) { model.draftKeys[index].category = $0 } })
            ) {
                Text("no category").tag(String?.none)
                ForEach(model.categories, id: \.id) { category in
                    Text(category.name).tag(String?.some(category.name))
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Button("×") {
                if model.draftKeys.indices.contains(index) {
                    model.draftKeys.remove(at: index)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Text.tertiary)
            Spacer(minLength: 0)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
