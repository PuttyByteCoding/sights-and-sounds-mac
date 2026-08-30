import SwiftUI
import SightsAndSoundsKit

/// One assignment box: a category's tags, or a media-item field.
///
/// The autocomplete offers words from the focused folder's name as
/// `folder`-badged rows beneath the real tags. Suggest, never
/// auto-apply — a filename parser that silently invents tags is
/// unpickable-apart later.
struct StagingBoxView: View {
    let box: ImportBox
    let vocabulary: [CategoryTags]
    let fields: [FieldDefinition]
    let folderWords: [String]
    @Binding var draft: StagingDraft
    let onSticky: (Bool) -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let category {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.categoryHue(category.category.colorIndex))
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 0)
                Button {
                    onSticky(!box.sticky)
                } label: {
                    Text("sticky")
                        .font(Theme.ui(9.5, box.sticky ? .bold : .regular))
                        .foregroundStyle(box.sticky ? Theme.Accent.amber : Theme.Text.disabled)
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .fill(box.sticky ? Theme.Surface.iconTileSelected : Theme.Surface.iconTile))
                }
                .buttonStyle(.plain)
                .help("Keep this box's value for the next import")
            }

            if let category {
                if !appliedTags(in: category).isEmpty {
                    FlowRow(spacing: 4) {
                        ForEach(appliedTags(in: category)) { tag in
                            pill(tag.name, hue: Theme.categoryHue(category.category.colorIndex)) {
                                draft.tagIDs.removeAll { $0 == tag.id }
                            }
                        }
                    }
                }
                field(placeholder: "Add \(category.category.name)…")
                ForEach(suggestions(in: category), id: \.self) { name in
                    suggestionRow(name, in: category, isFolderWord: false)
                }
                ForEach(folderSuggestions(in: category), id: \.self) { name in
                    suggestionRow(name, in: category, isFolderWord: true)
                }
            } else if let definition {
                TextField("Value", text: Binding(
                    get: { draft.fieldValues[definition.id] ?? "" },
                    set: { draft.fieldValues[definition.id] = $0.isEmpty ? nil : $0 })
                )
                .textFieldStyle(.plain)
                .font(Theme.ui(12))
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            }
        }
    }

    private var category: CategoryTags? {
        guard let id = box.categoryID else { return nil }
        return vocabulary.first { $0.category.id == id }
    }

    private var definition: FieldDefinition? {
        guard let id = box.fieldID else { return nil }
        return fields.first { $0.id == id }
    }

    private var title: String {
        category?.category.name ?? definition?.name ?? "Box"
    }

    private func appliedTags(in category: CategoryTags) -> [Tag] {
        category.tags.filter { draft.tagIDs.contains($0.id) }
    }

    private func suggestions(in category: CategoryTags) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return category.tags
            .filter {
                !draft.tagIDs.contains($0.id)
                    && $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            .prefix(5)
            .map(\.name)
    }

    /// Words from the folder, offered only when they are not already a
    /// tag being offered above.
    private func folderSuggestions(in category: CategoryTags) -> [String] {
        let existing = Set(category.tags.map { $0.name.lowercased() })
        return folderWords.filter { !existing.contains($0.lowercased()) }.prefix(3).map { $0 }
    }

    private func field(placeholder: String) -> some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .font(Theme.ui(12))
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func suggestionRow(
        _ name: String, in category: CategoryTags, isFolderWord: Bool
    ) -> some View {
        Button {
            apply(name, in: category)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.categoryHue(category.category.colorIndex))
                Text(name)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.secondary)
                if isFolderWord {
                    ThemeBadge(
                        text: "folder", fill: Theme.Surface.iconTile,
                        foreground: Theme.Text.disabled)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Staging holds tag IDs, so a suggested folder word has to become a
    /// real tag to be staged. It is created only when it is picked —
    /// suggesting never writes.
    private func apply(_ name: String, in category: CategoryTags) {
        if let existing = category.tags.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            draft.tagIDs.append(existing.id)
        } else {
            draft.pendingNames.append(PendingTagName(name: name, categoryID: category.category.id))
        }
        query = ""
    }

    private func pill(_ name: String, hue: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Theme.ui(11))
                .foregroundStyle(hue)
            Button {
                remove()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.ui(8))
                    .foregroundStyle(hue.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(hue.opacity(0.13)))
        .overlay(Capsule().stroke(hue.opacity(0.35), lineWidth: 1))
    }
}

/// A staged name that is not a tag yet. Created at import time through
/// `ensureTag`, so the category's formatting rule and its aliases both
/// apply — the same path typing the name anywhere else takes.
struct PendingTagName: Equatable {
    var name: String
    var categoryID: UUID
}

/// Which boxes the stage rail offers, and in what order.
struct ConfigureBoxesSheet: View {
    @Binding var boxes: [ImportBox]
    let categories: [TagCategory]
    let fields: [FieldDefinition]
    let onSave: ([ImportBox]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configure assignment boxes")
                    .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Check the tag categories and flags to show as assignment boxes, and set their order. Values staged there apply to every file in the import.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Categories").modifier(Theme.sectionLabel())
                        .padding(.bottom, 4)
                    ForEach(categories) { category in
                        row(
                            label: category.name,
                            hue: Theme.categoryHue(category.colorIndex),
                            isOn: boxes.contains { $0.categoryID == category.id },
                            toggle: { toggleCategory(category.id) })
                    }
                    if !fields.isEmpty {
                        Text("Media item fields").modifier(Theme.sectionLabel())
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(fields) { field in
                            row(
                                label: field.name,
                                hue: Theme.Text.quaternary,
                                isOn: boxes.contains { $0.fieldID == field.id },
                                toggle: { toggleField(field.id) })
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Done") {
                    onSave(boxes)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(Theme.Surface.dialog)
    }

    private func row(
        label: String, hue: Color, isOn: Bool, toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isOn ? Theme.Accent.amber : .clear)
                    .stroke(
                        isOn ? Theme.Accent.amber : Theme.Border.subtleButtonHover, lineWidth: 1)
                    .frame(width: 13, height: 13)
                RoundedRectangle(cornerRadius: 2).fill(hue).frame(width: 6, height: 6)
                Text(label)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleCategory(_ id: UUID) {
        if let index = boxes.firstIndex(where: { $0.categoryID == id }) {
            boxes.remove(at: index)
        } else {
            boxes.append(ImportBox(source: .category(id)))
        }
    }

    private func toggleField(_ id: UUID) {
        if let index = boxes.firstIndex(where: { $0.fieldID == id }) {
            boxes.remove(at: index)
        } else {
            boxes.append(ImportBox(source: .itemField(id)))
        }
    }
}
