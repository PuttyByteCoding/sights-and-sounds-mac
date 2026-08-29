import SwiftUI
import SightsAndSoundsKit

/// The in-place tag editor — right-click a tag, edit it where it is
/// (#108). Everything writes through the kit's single tagging write
/// path and refreshes through the model, so the change reconciles in
/// every window over the library. The Categories window remains the
/// bulk editor; this covers the tag in front of you.
struct TagEditorView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tag: Tag

    @State private var name: String
    @State private var notes: String
    @State private var hidden: Bool
    @State private var favorite: Bool
    @State private var newAlias = ""
    @State private var errorText: String?

    init(tag: Tag) {
        self.tag = tag
        _name = State(initialValue: tag.name)
        _notes = State(initialValue: tag.notes)
        _hidden = State(initialValue: tag.hiddenByDefault)
        _favorite = State(initialValue: tag.isFavorite)
    }

    private var aliases: [String] { model.tagAliases[tag.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Tag")
                .font(.headline)

            TextField("Name", text: $name)
                .onSubmit { save() }

            Toggle("Hidden by default", isOn: $hidden)
                .help("Items carrying this tag stay out of listings unless the filter names it")
            Toggle("Favorite", isOn: $favorite)

            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...4)

            Divider()

            Text("Aliases")
                .font(.subheadline)
            if aliases.isEmpty {
                Text("No aliases — search also finds this tag by its aliases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(aliases, id: \.self) { alias in
                HStack {
                    Text(alias)
                    Spacer()
                    Button("Remove alias", systemImage: "minus.circle") {
                        apply { try model.library.removeAlias(alias, fromTag: tag.id) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Add alias", text: $newAlias)
                    .onSubmit { addAlias() }
                Button("Add", action: addAlias)
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func addAlias() {
        let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        apply { try model.library.addAlias(trimmed, toTag: tag.id) }
        if errorText == nil { newAlias = "" }
    }

    /// One mutation, refreshed on success — alias edits land immediately.
    private func apply(_ mutation: () throws -> Void) {
        do {
            try mutation()
            errorText = nil
            model.refreshAll()
        } catch {
            errorText = "\(error)"
        }
    }

    /// Name, notes and the toggles commit together on Save. A refused
    /// rename (duplicate name) keeps the popover open with the error —
    /// merging is deliberately not a rename side effect.
    private func save() {
        do {
            if name != tag.name {
                try model.library.renameTag(tag.id, to: name)
            }
            if hidden != tag.hiddenByDefault {
                try model.library.setTagHidden(tag.id, hidden)
            }
            if favorite != tag.isFavorite {
                try model.library.setTagFavorite(tag.id, favorite)
            }
            if notes != tag.notes {
                try model.library.setTagNotes(tag.id, notes)
            }
            errorText = nil
            model.refreshAll()
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }
}
