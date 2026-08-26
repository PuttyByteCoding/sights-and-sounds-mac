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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Key Bindings").font(.title3)

            let bindings = model.boundKeys.values.sorted { $0.key < $1.key }
            if bindings.isEmpty {
                Text("No bindings yet. A bound key toggles its tag on the playing item.")
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

                Picker("Tag", selection: $selectedTagID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.panelVocabulary) { entry in
                        ForEach(entry.tags) { tag in
                            Text("\(entry.category.name) · \(tag.name)").tag(UUID?.some(tag.id))
                        }
                    }
                }

                Toggle("Advance", isOn: $advance)
                    .help("Applying the tag also moves to the next item")

                Button("Bind") { bind() }
                    .disabled(selectedTagID == nil)
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
        } catch {
            errorText = "\(error)"
        }
    }
}
