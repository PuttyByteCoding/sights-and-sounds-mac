import SwiftUI
import SightsAndSoundsKit

/// Manage key → tag bindings for this library. Bindable keys are the ones
/// the player's fixed map leaves free; each binding can optionally advance
/// to the next item when its tag is applied.
struct KeyBindingsEditor: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKey = TagKeyBinding.bindableKeys[0]
    @State private var selectedTagID: UUID?
    @State private var advance = false
    @State private var errorText: String?
    @State private var query = ""
    @State private var highlighted: TagPick?
    @FocusState private var queryFocused: Bool

    /// Every tag as a pick, category name alongside, so the search
    /// reaches "band phish" and "phish" alike.
    private var picks: [TagPick] {
        model.panelVocabulary.flatMap { entry in
            entry.tags.map { TagPick(tag: $0, categoryName: entry.category.name) }
        }
    }

    private func pick(_ id: UUID) -> TagPick? { picks.first { $0.id == id } }

    /// The matches shown under the field: the picker's own narrowing,
    /// capped so the sheet stays a sheet.
    private var matches: [TagPick] {
        Array(TagPickerSheet.candidates(picks, excluding: UUID(), query: query).prefix(8))
    }

    private func choose(_ row: TagPick) {
        selectedTagID = row.id
        query = ""
        highlighted = nil
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let rows = matches
        guard !rows.isEmpty else { return .handled }
        let current = highlighted.flatMap { row in rows.firstIndex { $0.id == row.id } } ?? 0
        highlighted = rows[min(max(0, current + delta), rows.count - 1)]
        return .handled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Key Bindings").font(.title3)

            let bindings = model.boundKeys.values.sorted { $0.key < $1.key }
            if bindings.isEmpty {
                Text("No bindings yet. A bound key toggles its tag on the playing item. Digits stamp from inside a tag field too.")
                    .foregroundStyle(.secondary)
            } else {
                List(bindings, id: \.key) { binding in
                    HStack {
                        Text(binding.key.count == 1 ? binding.key.uppercased() : binding.key)
                            .font(.body.monospaced())
                            .frame(width: 36, alignment: .leading)
                        Text(tagName(binding.tagID))
                        if binding.advance {
                            Text("advances").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            try? model.library.removeKeyBinding(binding.key)
                            model.refreshTagging()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 140)
            }

            Divider()

            HStack {
                Picker("Key", selection: $selectedKey) {
                    ForEach(availableKeys, id: \.self) { key in
                        Text(key.count == 1 ? key.uppercased() : key).tag(key)
                    }
                }
                .frame(width: 110)

                // The tag is FOUND, not scrolled to: a popup of the whole
                // vocabulary is unusable past a few hundred tags. Type,
                // pick from the matches (↑ ↓, Enter), and the pick shows
                // as a chip until it is bound or cleared.
                if let picked = selectedTagID.flatMap(pick) {
                    HStack(spacing: 6) {
                        Text("\(picked.categoryName) · \(picked.tag.name)")
                            .font(Theme.ui(12))
                        Button {
                            selectedTagID = nil
                            query = ""
                            queryFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.Text.disabled)
                        }
                        .buttonStyle(.plain)
                        .help("Pick a different tag")
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Theme.Surface.well))
                } else {
                    TextField("Find a tag…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($queryFocused)
                        .onSubmit {
                            if let row = highlighted ?? matches.first { choose(row) }
                        }
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .onChange(of: query) { _, _ in highlighted = nil }
                }

                Toggle("Advance", isOn: $advance)
                    .help("Applying the tag also moves to the next item")

                Button("Bind") { bind() }
                    .disabled(selectedTagID == nil)
            }

            if selectedTagID == nil, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No tag matches that.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .padding(8)
                    }
                    ForEach(matches) { row in
                        let active = (highlighted ?? matches.first)?.id == row.id
                        Button {
                            choose(row)
                        } label: {
                            HStack(spacing: 6) {
                                Text(row.tag.name).font(Theme.ui(12))
                                Spacer(minLength: 6)
                                Text(row.categoryName)
                                    .font(Theme.ui(10))
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                    .fill(active ? Theme.Surface.selectedRow : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480)
    }

    private var availableKeys: [String] {
        TagKeyBinding.bindableKeys.filter { model.boundKeys[$0] == nil || $0 == selectedKey }
    }

    private func tagName(_ id: UUID) -> String {
        for entry in model.panelVocabulary {
            if let tag = entry.tags.first(where: { $0.id == id }) {
                return "\(entry.category.name) · \(tag.name)"
            }
        }
        return "(deleted tag)"
    }

    private func bind() {
        guard let tagID = selectedTagID else { return }
        do {
            try model.library.setKeyBinding(selectedKey, tagID: tagID, advance: advance)
            model.refreshTagging()
            errorText = nil
            selectedTagID = nil
            queryFocused = true
        } catch {
            errorText = "\(error)"
        }
    }
}
