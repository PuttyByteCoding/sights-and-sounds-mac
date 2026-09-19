import SwiftUI
import SightsAndSoundsKit

/// The search strings as a panel in the player's right rail (spec 17,
/// decision 9): every format the library has, rendered for the shown
/// item. The default leads under "⌘⇧C copies" — always the string the
/// shortcut would copy — and the other formats follow, each with a
/// button to make it the default. A click on any string copies it.
///
/// It is also where a format is made and edited: Edit on a row, or
/// New, opens the recipe editor in the panel with the string the
/// shown item would give at the top, rewritten on every keystroke.
/// Save writes it to the library; Cancel drops the draft.
struct SearchPanel: View {
    @Environment(PlayerModel.self) private var model
    @Environment(BrowseModel.self) private var browse
    /// The format being edited, as a draft: the list is hidden while
    /// it is up, and only Save touches the library.
    @State private var draft: SearchRecipe?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search").modifier(Theme.sectionLabel())
                Spacer()
                if draft == nil {
                    Text(model.searchFormats.formats.isEmpty ? "" : "\(model.searchFormats.formats.count)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                    Button {
                        let count = model.searchFormats.formats.count
                        draft = SearchRecipe(name: count == 0 ? "Default" : "Format \(count + 1)")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New format")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if let draftBinding = Binding($draft) {
                editor(draftBinding)
            } else if model.searchFormats.formats.isEmpty {
                Text("No search formats yet — press + to make one, or add it in Settings › Search String.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
            } else {
                // A plain stack, not a scroll view: the panel is sized to
                // its content so the rail's flexible panels cannot squeeze
                // it to nothing, and a scroll view has no content height
                // of its own.
                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        // The default leads, and says so: this is the
                        // string ⌘⇧C copies, whatever else is listed.
                        if let primary = model.searchFormats.defaultFormat {
                            Text("⌘⇧C copies")
                                .font(Theme.ui(9.5, .semibold))
                                .foregroundStyle(Theme.Accent.amber)
                                .padding(.horizontal, 4)
                            row(primary, isDefault: true)
                        }
                        let others = model.searchFormats.formats.filter { $0.id != model.searchFormats.defaultFormat?.id }
                        if !others.isEmpty {
                            Text("Other formats")
                                .font(Theme.ui(9.5, .semibold))
                                .foregroundStyle(Theme.Text.quaternary)
                                .padding(.horizontal, 4)
                                .padding(.top, 6)
                            ForEach(others) { row($0, isDefault: false) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                Text("Click a string to copy it · Edit to change it · “Use for ⌘⇧C” moves the default")
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The editor: the live string first — what ⌘⇧C would copy for the
    /// shown item if this draft were saved — then the name, the parts,
    /// the rules, and Save / Cancel.
    private func editor(_ draft: Binding<SearchRecipe>) -> some View {
        let string = model.searchSubject.map { SearchStringBuilder.string(recipe: draft.wrappedValue, subject: $0) } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Would copy")
                    .font(Theme.ui(9.5, .semibold))
                    .foregroundStyle(Theme.Accent.amber)
                Text(string.isEmpty ? "(nothing for this item yet)" : string)
                    .font(Theme.mono(11))
                    .foregroundStyle(string.isEmpty ? Theme.Text.disabled : Theme.Text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Accent.amber, lineWidth: 1))

            HStack(spacing: 6) {
                Text("Name")
                    .font(Theme.ui(10.5, .semibold))
                    .foregroundStyle(.secondary)
                TextField("Format name", text: draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Parts").font(Theme.ui(9.5, .semibold)).foregroundStyle(Theme.Text.quaternary)
            RecipeParts(recipe: draft, categories: model.panelVocabulary.map(\.category), compact: true)
            Text("Rules").font(Theme.ui(9.5, .semibold)).foregroundStyle(Theme.Text.quaternary).padding(.top, 4)
            RecipeRules(recipe: draft, compact: true, preview: model.searchSubject)

            // No key equivalents: in the player window Return belongs to
            // the tag fields and Esc to the focus stack, and a Save that
            // fired from a tag field would be a surprise.
            HStack {
                Button("Cancel") { self.draft = nil }
                Spacer()
                Button("Save") {
                    model.saveSearchFormat(draft.wrappedValue)
                    self.draft = nil
                }
                .disabled(draft.wrappedValue.parts.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func row(_ format: SearchRecipe, isDefault: Bool) -> some View {
        let string = model.searchSubject.map { SearchStringBuilder.string(recipe: format, subject: $0) } ?? ""
        return HStack(alignment: .top, spacing: 6) {
            Button {
                guard !string.isEmpty else { return }
                Clipboard.copy(string)
                browse.showSearchNotice("Copied: \(string)")
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(format.name.isEmpty ? "Untitled" : format.name)
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text(string.isEmpty ? "(nothing for this item)" : string)
                        .font(Theme.mono(11))
                        .foregroundStyle(string.isEmpty ? Theme.Text.disabled : Theme.Text.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(string.isEmpty)
            .help(string.isEmpty ? "The format yields nothing for this item" : "Copy this string")

            Button {
                draft = format
            } label: {
                Image(systemName: "pencil")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .buttonStyle(.plain)
            .help("Edit this format here")
            if !isDefault {
                Button {
                    model.setDefaultSearchFormat(format.id)
                } label: {
                    Text("Use for ⌘⇧C")
                        .font(Theme.ui(9.5))
                        .foregroundStyle(Theme.Text.tertiary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Theme.Border.subtleButton, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Make this the format ⌘⇧C, ⌘⇧F and ⌘⇧B use")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.well)
                .stroke(isDefault ? Theme.Accent.amber : Theme.Border.standard, lineWidth: 1))
    }
}
