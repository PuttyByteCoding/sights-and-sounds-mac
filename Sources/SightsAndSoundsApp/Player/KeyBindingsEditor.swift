import SwiftUI
import SightsAndSoundsKit

/// Manage key → tag bindings for this library. Bindable keys are the ones
/// the player's fixed map leaves free; each binding can optionally advance
/// to the next item when its tag is applied.
struct KeyBindingsEditor: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKey = TagKeyBinding.bindableKeys[0]
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

    /// The matches shown under the field: the picker's own ranking —
    /// an exact name first — and every one of them; the list scrolls.
    private var matches: [TagPick] {
        TagPickerSheet.candidates(picks, excluding: UUID(), query: query)
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
                        Spacer()
                        // The flag is edited where it is read: flip it on
                        // the row, and the binding is rewritten at once.
                        Toggle("Advances", isOn: Binding(
                            get: { binding.advance },
                            set: { flag in
                                do {
                                    try model.library.setKeyBinding(
                                        binding.key, tagID: binding.tagID, advance: flag)
                                    model.refreshTagging()
                                    errorText = nil
                                } catch { errorText = "\(error)" }
                            }))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Applying the tag also moves to the next item")
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
                // pick from the matches (↑ ↓, Enter, or a click) — and the
                // pick IS the bind, with the Advance toggle as its flag.
                // The row appears above; the field clears for the next.
                TextField("Find a tag to bind to \(selectedKey.count == 1 ? selectedKey.uppercased() : selectedKey)…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit {
                        if let row = highlighted ?? matches.first { bind(row) }
                    }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onChange(of: query) { _, _ in highlighted = nil }

                Toggle("Advance", isOn: $advance)
                    .help("New bindings advance to the next item when their tag is applied")
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                  LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No tag matches that.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .padding(8)
                    }
                    ForEach(matches) { row in
                        let active = (highlighted ?? matches.first)?.id == row.id
                        Button {
                            bind(row)
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
                        .id(row.id)
                    }
                  }
                  .padding(4)
                }
                .frame(maxHeight: 220)
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

    /// Bind the picked tag to the selected key and move on: the field
    /// clears, the key picker steps to the next free key so a run of
    /// bindings is type · Enter · type · Enter.
    private func bind(_ row: TagPick) {
        do {
            try model.library.setKeyBinding(selectedKey, tagID: row.id, advance: advance)
            model.refreshTagging()
            errorText = nil
            query = ""
            highlighted = nil
            if let next = TagKeyBinding.bindableKeys.first(where: { model.boundKeys[$0] == nil && $0 != selectedKey }) {
                selectedKey = next
            }
            queryFocused = true
        } catch {
            errorText = "\(error)"
        }
    }
}
