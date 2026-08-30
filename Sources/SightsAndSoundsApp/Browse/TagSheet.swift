import SwiftUI
import SightsAndSoundsKit

/// Creating a tag and editing one, in one sheet.
///
/// They were two views with the same five fields in different orders —
/// the in-place editor reachable only by ⌥-click from the sidebar, and a
/// creation sheet in the player. Two implementations of "what a tag is"
/// is how they drift, and one of them was already the only place you
/// could set a note.
///
/// It depends on the LIBRARY, not on a model, because it is opened from
/// both the browse window (BrowseModel) and the player's tag panel
/// (PlayerModel). Callers hand it a library and a refresh callback; it
/// knows nothing about either.
struct TagSheet: View {
    enum Mode {
        /// A name typed into a category's tagging field.
        case create(categoryID: UUID, name: String)
        case edit(Tag)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let mode: Mode
    let library: LibraryDatabase
    let libraryID: UUID
    let categories: [TagCategory]
    /// The library changed — callers refresh however they refresh.
    let onSaved: (Tag) -> Void

    @State private var categoryID: UUID
    @State private var name: String
    @State private var notes: String
    @State private var hidden: Bool
    @State private var favorite: Bool
    @State private var aliases: [String] = []
    @State private var newAlias = ""
    @State private var errorText: String?
    /// Create only: the Enter that opened the sheet is still down, so it
    /// commits — until the first key or click, after which the buttons
    /// take over. Editing has no such in-flight Enter, so it uses the
    /// ordinary default action instead.
    @State private var enterArmed: Bool
    @FocusState private var nameFocused: Bool

    init(
        mode: Mode, library: LibraryDatabase, libraryID: UUID,
        categories: [TagCategory], onSaved: @escaping (Tag) -> Void
    ) {
        self.mode = mode
        self.library = library
        self.libraryID = libraryID
        self.categories = categories
        self.onSaved = onSaved
        switch mode {
        case .create(let categoryID, let name):
            _categoryID = State(initialValue: categoryID)
            _name = State(initialValue: name)
            _notes = State(initialValue: "")
            _hidden = State(initialValue: false)
            _favorite = State(initialValue: false)
            _enterArmed = State(initialValue: true)
        case .edit(let tag):
            _categoryID = State(initialValue: tag.tagCategoryID)
            _name = State(initialValue: tag.name)
            _notes = State(initialValue: tag.notes)
            _hidden = State(initialValue: tag.hiddenByDefault)
            _favorite = State(initialValue: tag.isFavorite)
            _enterArmed = State(initialValue: false)
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var editingTag: Tag? {
        if case .edit(let tag) = mode { return tag }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(isCreating ? "New Tag" : "Edit Tag")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)

            LabeledRow("Group") {
                Picker("", selection: $categoryID) {
                    ForEach(categories) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .labelsHidden()
                // A tag can be created into any category; moving an
                // existing one between categories is a merge question,
                // not a rename, and the kit has no such write.
                .disabled(!isCreating)
                .help(isCreating
                    ? "The category this tag is created in"
                    : "A tag cannot change category — merge it from the Categories window instead")
            }

            LabeledRow("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(
                                nameFocused ? Theme.Border.activeControl : Theme.Border.standard,
                                lineWidth: nameFocused ? 2 : 1))
                    .focused($nameFocused)
            }

            LabeledRow("Favorite") {
                Button {
                    favorite.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(Theme.ui(14))
                            .foregroundStyle(favorite ? Theme.Accent.amber : Theme.Text.disabled)
                        Text(favorite ? "Favorite" : "Not a favorite")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            LabeledRow("Aliases") {
                VStack(alignment: .leading, spacing: 6) {
                    if !aliases.isEmpty {
                        FlowRow(spacing: 5) {
                            ForEach(aliases, id: \.self) { alias in
                                HStack(spacing: 4) {
                                    Text(alias).font(Theme.ui(11.5))
                                    Button {
                                        removeAlias(alias)
                                    } label: {
                                        Image(systemName: "xmark").font(Theme.ui(8, .semibold))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(Capsule().fill(Theme.Surface.iconTile))
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Add alias and press Enter", text: $newAlias)
                            .textFieldStyle(.plain)
                            .font(Theme.ui(12))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 9)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(Theme.Surface.well)
                                    .stroke(Theme.Border.standard, lineWidth: 1))
                            .onSubmit(addAlias)
                        Button("Add", action: addAlias)
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            LabeledRow("Notes") {
                TextField("", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .lineLimit(3...5)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(Theme.Border.standard, lineWidth: 1))
            }

            LabeledRow("Hidden by default") {
                HStack(spacing: 9) {
                    Toggle("", isOn: $hidden)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text("Hide items with this tag unless you filter for it.")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }

            Text(hintLine)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)

            if let errorText {
                Text(errorText)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Status.orange)
            }

            HStack(spacing: 10) {
                Button("Manage Tags…") {
                    openWindow(
                        id: "aux",
                        value: AuxWindowRequest(libraryID: libraryID, kind: .categories))
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Categories & Fields — the bulk editor")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(isCreating ? "Create" : "Save") { commit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmedName.isEmpty)
                    // Only editing gets the ordinary default action;
                    // creating manages Enter itself, below.
                    .keyboardShortcut(isCreating ? .init("\u{1B}") : .defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Theme.Surface.dialog)
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            if isCreating, press.key == .return, enterArmed {
                commit()
                return .handled
            }
            enterArmed = false
            return .ignored
        }
        .onTapGesture { enterArmed = false }
        .onAppear {
            nameFocused = true
            loadAliases()
        }
    }

    private var hintLine: String {
        if isCreating && enterArmed {
            return "Enter creates it · Esc to cancel · edit anything below and Enter stops committing"
        }
        return isCreating
            ? "Esc to cancel · Create when you are ready"
            : "Enter saves · Esc to cancel"
    }

    /// Edit mode reads the tag's aliases from the library; create mode
    /// starts empty and writes them once the tag exists.
    private func loadAliases() {
        guard let tag = editingTag, aliases.isEmpty else { return }
        aliases = (try? library.writer.read { db in
            try TagAlias
                .filter(sql: "tagID = ?", arguments: [tag.id])
                .fetchAll(db)
                .map(\.alias)
        }) ?? []
    }

    private func addAlias() {
        let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !aliases.contains(trimmed) else { return }
        // Editing writes immediately — an alias is its own fact, and a
        // half-finished rename should not take it with it.
        if let tag = editingTag {
            do { try library.addAlias(trimmed, toTag: tag.id) } catch {
                errorText = "\(error)"
                return
            }
        }
        aliases.append(trimmed)
        newAlias = ""
    }

    private func removeAlias(_ alias: String) {
        if let tag = editingTag {
            do { try library.removeAlias(alias, fromTag: tag.id) } catch {
                errorText = "\(error)"
                return
            }
        }
        aliases.removeAll { $0 == alias }
    }

    /// Both paths go through the kit's single tagging writes, so neither
    /// can mint a rival spelling or rename onto an existing name.
    private func commit() {
        guard !trimmedName.isEmpty else { return }
        do {
            let tag: Tag
            if let existing = editingTag {
                if trimmedName != existing.name {
                    try library.renameTag(existing.id, to: trimmedName)
                }
                if hidden != existing.hiddenByDefault {
                    try library.setTagHidden(existing.id, hidden)
                }
                if favorite != existing.isFavorite {
                    try library.setTagFavorite(existing.id, favorite)
                }
                if notes != existing.notes {
                    try library.setTagNotes(existing.id, notes)
                }
                tag = existing
            } else {
                let created = try library.ensureTag(named: trimmedName, inCategory: categoryID)
                for alias in aliases { try library.addAlias(alias, toTag: created.id) }
                if hidden { try library.setTagHidden(created.id, true) }
                if favorite { try library.setTagFavorite(created.id, true) }
                if !notes.isEmpty { try library.setTagNotes(created.id, notes) }
                tag = created
            }
            errorText = nil
            onSaved(tag)
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }
}

/// A fixed label gutter so every control starts on the same line,
/// whatever the label says.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 104, alignment: .leading)
                .padding(.top, 7)
            content
        }
    }
}
