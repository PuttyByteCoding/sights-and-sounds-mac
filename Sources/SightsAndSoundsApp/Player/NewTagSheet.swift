import SwiftUI
import SightsAndSoundsKit

/// Creating a tag from the tagging field, with everything a tag can carry
/// available before it exists rather than after.
///
/// The Enter that opens this sheet is still "down" in the user's head, so
/// Enter commits immediately — the fast path is type, Enter, Enter. But
/// it **disarms the moment you touch anything**: any key, any click, and
/// Enter stops being the commit. Otherwise a second Enter aimed at a
/// field you had started editing would create a tag you were still
/// writing, which is the one mistake this dialog exists to prevent.
///
/// Esc always cancels, armed or not.
struct NewTagSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let categoryID: UUID
    let initialName: String
    /// Called with the created tag so the caller can apply it.
    let onCreate: (Tag) -> Void

    @State private var name: String
    @State private var notes = ""
    @State private var hidden = false
    @State private var favorite = false
    @State private var aliases: [String] = []
    @State private var newAlias = ""
    @State private var errorText: String?
    /// Enter still commits. Cleared by the first key or click.
    @State private var enterArmed = true
    @FocusState private var nameFocused: Bool

    init(categoryID: UUID, initialName: String, onCreate: @escaping (Tag) -> Void) {
        self.categoryID = categoryID
        self.initialName = initialName
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
    }

    private var category: TagCategory? {
        model.panelVocabulary.first { $0.category.id == categoryID }?.category
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)

            LabeledRow("Group") {
                // A picker, not a label: a tag typed into the wrong
                // category should be redirected rather than cancelled.
                Picker("", selection: Binding(
                    get: { categoryID },
                    set: { _ in })
                ) {
                    ForEach(model.panelVocabulary) { entry in
                        Text(entry.category.name).tag(entry.category.id)
                    }
                }
                .labelsHidden()
                .disabled(true)
                .help("The category this tag is being created in")
            }

            LabeledRow("Name") {
                HStack(spacing: 10) {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12.5))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(
                                    nameFocused
                                        ? Theme.Border.activeControl : Theme.Border.standard,
                                    lineWidth: nameFocused ? 2 : 1))
                        .focused($nameFocused)
                    Button {
                        favorite.toggle()
                    } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(Theme.ui(15))
                            .foregroundStyle(favorite ? Theme.Accent.amber : Theme.Text.disabled)
                    }
                    .buttonStyle(.plain)
                    .help("Favorite")
                }
            }

            LabeledRow("Aliases") {
                VStack(alignment: .leading, spacing: 6) {
                    if !aliases.isEmpty {
                        FlowRow(spacing: 5) {
                            ForEach(aliases, id: \.self) { alias in
                                HStack(spacing: 4) {
                                    Text(alias).font(Theme.ui(11.5))
                                    Button {
                                        aliases.removeAll { $0 == alias }
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

            LabeledRow("Hidden") {
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
                Button("Manage tags…") {
                    openWindow(
                        id: "aux",
                        value: AuxWindowRequest(libraryID: model.libraryID, kind: .categories))
                }
                .buttonStyle(.plain)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Create") { create() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 430)
        .background(Theme.Surface.dialog)
        // Every key goes through here first. Enter commits only while
        // armed; anything else disarms it and falls through to whatever
        // field has focus.
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            if press.key == .return, enterArmed {
                create()
                return .handled
            }
            enterArmed = false
            return .ignored
        }
        // A click is engagement too — the same disarm, so Enter cannot
        // commit after you have started pointing at things.
        .onTapGesture { enterArmed = false }
        .onAppear { nameFocused = true }
    }

    private var hintLine: String {
        enterArmed
            ? "Enter creates it · Esc to cancel · edit anything below and Enter stops committing"
            : "Esc to cancel · Create when you are ready"
    }

    private func addAlias() {
        let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !aliases.contains(trimmed) else { return }
        aliases.append(trimmed)
        newAlias = ""
    }

    /// Everything goes through the kit's single write path: `ensureTag`
    /// normalizes the name per the category and resolves an existing
    /// alias to its tag, so this cannot mint a rival spelling.
    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            let tag = try model.library.ensureTag(named: trimmedName, inCategory: categoryID)
            for alias in aliases {
                try model.library.addAlias(alias, toTag: tag.id)
            }
            if hidden { try model.library.setTagHidden(tag.id, true) }
            if favorite { try model.library.setTagFavorite(tag.id, true) }
            if !notes.isEmpty { try model.library.setTagNotes(tag.id, notes) }
            model.refreshTagging()
            onCreate(tag)
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }
}

/// The mockup's two-column form: a fixed label gutter so every control
/// starts on the same line, whatever the label says.
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
                .frame(width: 66, alignment: .leading)
                .padding(.top, 7)
            content
        }
    }
}
