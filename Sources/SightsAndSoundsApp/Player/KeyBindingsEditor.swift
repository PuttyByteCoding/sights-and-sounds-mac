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
    /// reaches "band phish" and "phish" alike. Built once on appear —
    /// the fold lives in the pick — not flattened and re-folded on every
    /// read.
    @State private var picks: [TagPick] = []
    /// The matches shown under the field: the picker's own ranking — an
    /// exact name first — and every one of them; the list scrolls.
    /// State, recomputed when the query changes, because as a computed
    /// property it was read once per ROW while drawing the list (each
    /// row's highlight asked for the first match), which ranked the
    /// whole vocabulary a thousand times per keystroke.
    @State private var matches: [TagPick] = []
    private var namesByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: picks.map { ($0.id, "\($0.categoryName) · \($0.tag.name)") })
    }

    private func rebuildPicks() {
        picks = model.panelVocabulary.flatMap { entry in
            entry.tags.map { TagPick(tag: $0, categoryName: entry.category.name) }
        }
        rebuildMatches()
    }

    private func rebuildMatches() {
        matches = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? [] : TagPickerSheet.candidates(picks, excluding: UUID(), query: query)
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
            Text("Tag Key Bindings")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)

            let bindings = model.boundKeys.values.sorted { $0.key < $1.key }
            let names = namesByID
            if bindings.isEmpty {
                Text("No bindings yet. A bound key toggles its tag on the playing item. Digits stamp from inside a tag field too.")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Themed rows on a raised plate, not a system List: the
                // sheet sits inside a charcoal window and must read as
                // part of it (design review 2026-10-20, S5).
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(bindings, id: \.key) { binding in
                            bindingRow(binding, name: names[binding.tagID])
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.raised)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            }

            Divider().overlay(Theme.Border.standard)

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
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused($queryFocused)
                    .onSubmit {
                        if let row = highlighted ?? matches.first { bind(row) }
                    }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onChange(of: query) { _, _ in highlighted = nil }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.well)
                            .stroke(
                                queryFocused ? Theme.Border.activeControl : Theme.Border.standard,
                                lineWidth: 1))

                Toggle("Advance", isOn: $advance)
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.secondary)
                    .help("New bindings advance to the next item when their tag is applied")
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                  LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No tag matches that.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.meta)
                            .padding(8)
                    }
                    let first = highlighted ?? matches.first
                    ForEach(matches) { row in
                        let active = first?.id == row.id
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
                            .highlightedSuggestion(active)
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
                Text(errorText)
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Status.red)
            }

            HStack {
                Spacer()
                // Done is the one button: the primary, so Return; and the
                // way out, so Esc. A button carries one shortcut, so the
                // cancel key is bound to an unseen twin of it.
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .background {
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                            .accessibilityHidden(true)
                    }
            }
        }
        .padding(16)
        .frame(minWidth: 480)
        .background(Theme.Surface.dialog)
        .onAppear(perform: rebuildPicks)
        .onChange(of: query) { _, _ in rebuildMatches() }
    }

    /// One bound key: the key in mono, the tag with its category, the
    /// Advances flag edited where it is read, and Remove.
    private func bindingRow(_ binding: TagKeyBinding, name: String?) -> some View {
        HStack(spacing: 10) {
            Text(binding.key.count == 1 ? binding.key.uppercased() : binding.key)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Text.primary)
                .frame(width: 36, alignment: .leading)
            Text(name ?? "(deleted tag)")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(name == nil ? Theme.Text.quaternary : Theme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            // The flag is edited where it is read: flip it on the row,
            // and the binding is rewritten at once.
            Toggle("Advances", isOn: Binding(
                get: { binding.advance },
                set: { flag in
                    Task {
                        errorText = await model.setKeyBinding(
                            binding.key, tagID: binding.tagID, advance: flag)
                    }
                }))
                .toggleStyle(.checkbox)
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.tertiary)
                .help("Applying the tag also moves to the next item")
            Button {
                Task { _ = await model.removeKeyBinding(binding.key) }
            } label: {
                Image(systemName: "trash")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the binding for \(binding.key.uppercased())")
            .help("Remove this binding")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
    }

    private var availableKeys: [String] {
        TagKeyBinding.bindableKeys.filter { model.boundKeys[$0] == nil || $0 == selectedKey }
    }

    /// Bind the picked tag to the selected key and move on: the field
    /// clears, the key picker steps to the next free key so a run of
    /// bindings is type · Enter · type · Enter.
    private func bind(_ row: TagPick) {
        // The key and the flag as they were at the press: the picker may
        // have moved by the time the binding has been made.
        let key = selectedKey, advances = advance
        Task {
            if let problem = await model.setKeyBinding(key, tagID: row.id, advance: advances) {
                errorText = problem
                return
            }
            errorText = nil
            query = ""
            highlighted = nil
            if let next = TagKeyBinding.bindableKeys.first(where: { model.boundKeys[$0] == nil && $0 != key }) {
                selectedKey = next
            }
            queryFocused = true
        }
    }
}
