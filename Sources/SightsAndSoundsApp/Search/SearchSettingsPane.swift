import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Settings › Search String (spec 17, decision 7): the library's search
/// formats — several, named, one of them the default the menu uses —
/// each edited as rows of parts and rules with a live preview; and,
/// app-wide, the Firefox profile and the web search URL. The page is a
/// draft: the preview follows every edit, and Apply is what writes it.
struct SearchSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedLibraryID: UUID?
    @State private var formats = SearchFormats.empty
    /// What the library holds. Apply moves the draft here.
    @State private var savedFormats = SearchFormats.empty
    @State private var selectedFormatID: UUID?
    @State private var categories: [TagCategory] = []
    /// The preview's file name: the library's first item's to start,
    /// then whatever is typed — a name with the shape in question, not
    /// whichever file sorts first. The tags stay the first item's.
    @State private var sampleFileName = ""
    @State private var sampleTags: [SearchSubjectTag] = []
    @State private var statusText: String?
    @State private var firefoxProfile = AppSettingsStore.shared.current.firefoxProfilePath ?? ""
    @State private var webSearchURL = AppSettingsStore.shared.current.webSearchURL

    var body: some View {
        Form {
            ScopeHeader(scope: .library)
            Section("Search String") {
                Picker("Library", selection: $selectedLibraryID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.libraries) { library in
                        Text(library.name).tag(UUID?.some(library.id))
                    }
                }
                Text("One string per video per format, built from its file name and tags in the order below. ⌘⇧C copies the default format's string, ⌘⇧F searches the web with it, ⌘⇧B searches Firefox's bookmarks for its values; the player's Search panel shows every format. Nothing takes effect until Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selectedLibraryID != nil {
                formatsSection
                if selectedFormatID != nil {
                    partsSection
                    rulesSection
                    previewSection
                }
            }
            firefoxSection
            applySection
        }
        .formStyle(.grouped)
        .onChange(of: selectedLibraryID) { load() }
    }

    /// Anything on the page that differs from what is stored.
    private var isDirty: Bool {
        let settings = AppSettingsStore.shared.current
        return (selectedLibraryID != nil && formats != savedFormats)
            || firefoxProfile != (settings.firefoxProfilePath ?? "")
            || webSearchURL != settings.webSearchURL
    }

    private var applySection: some View {
        Section {
            HStack {
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
                Button("Revert") { load() }
                    .disabled(!isDirty)
                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Formats

    /// The format being edited, as a value the sections read and write
    /// through — a change lands in `formats` at once.
    private var recipe: SearchRecipe {
        get { formats.formats.first { $0.id == selectedFormatID } ?? .empty }
        nonmutating set {
            guard let index = formats.formats.firstIndex(where: { $0.id == selectedFormatID }) else { return }
            formats.formats[index] = newValue
        }
    }

    private var recipeBinding: Binding<SearchRecipe> {
        Binding(get: { recipe }, set: { recipe = $0 })
    }

    private var isDefaultFormat: Binding<Bool> {
        Binding(
            get: { formats.defaultFormat?.id == selectedFormatID && selectedFormatID != nil },
            set: { on in formats.defaultID = on ? selectedFormatID : nil })
    }

    private var formatsSection: some View {
        Section {
            if formats.formats.isEmpty {
                Text("No formats yet. Add one to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Format", selection: $selectedFormatID) {
                    ForEach(formats.formats) { format in
                        Text(format.name.isEmpty ? "Untitled" : format.name).tag(UUID?.some(format.id))
                    }
                }
                LabeledContent("Name") {
                    TextField("Name", text: recipeBinding.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                Toggle("Use for ⌘⇧C, ⌘⇧F and ⌘⇧B", isOn: isDefaultFormat)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Button("Add Format") {
                    let added = SearchRecipe(name: formats.formats.isEmpty ? "Default" : "Format \(formats.formats.count + 1)")
                    formats.formats.append(added)
                    if formats.defaultID == nil { formats.defaultID = added.id }
                    selectedFormatID = added.id
                }
                Button("Remove Format") {
                    guard let id = selectedFormatID else { return }
                    formats.formats.removeAll { $0.id == id }
                    if formats.defaultID == id { formats.defaultID = formats.formats.first?.id }
                    selectedFormatID = formats.formats.first?.id
                }
                .disabled(selectedFormatID == nil)
            }
        } header: {
            Text("Formats")
        } footer: {
            Text("Several formats, one library. The player's Search panel shows every format's string and copies one on a click; the menu commands use the one marked here, which the panel's ⌘⇧C marker can also move.")
        }
    }

    // MARK: Parts

    private var partsSection: some View {
        Section {
            if recipe.parts.isEmpty {
                Text("No parts yet. Add one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(recipeBinding.parts) { $part in
                PartRow(
                    part: $part, categories: categories,
                    isFirst: recipe.parts.first?.id == part.id,
                    isLast: recipe.parts.last?.id == part.id,
                    onMove: { delta in movePart(part.id, by: delta) },
                    onRemove: { recipe.parts.removeAll { $0.id == part.id } })
            }
            Menu("Add Part") {
                Button("Text") { recipe.parts.append(SearchPart(kind: .literal(""))) }
                Button("File name") {
                    recipe.parts.append(SearchPart(
                        kind: .fileName(includesExtension: false, splitsPieces: true),
                        format: SearchFormat(quoting: .multiWord)))
                }
                Button("Tags") {
                    recipe.parts.append(SearchPart(
                        kind: .tags(categoryID: categories.first?.id, joiner: " "),
                        format: SearchFormat(quoting: .multiWord)))
                }
            }
            .fixedSize()
        } header: {
            Text("Parts")
        } footer: {
            Text("Top to bottom, joined with spaces. Text is used as typed; file name and tag parts take the case and quoting beside them.")
        }
    }

    private func movePart(_ id: UUID, by delta: Int) {
        var parts = recipe.parts
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard parts.indices.contains(target) else { return }
        parts.swapAt(index, target)
        recipe.parts = parts
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            if recipe.rules.isEmpty {
                Text("No rules yet. Add one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(recipeBinding.rules) { $rule in
                RuleRow(
                    rule: $rule,
                    isFirst: recipe.rules.first?.id == rule.id,
                    isLast: recipe.rules.last?.id == rule.id,
                    onMove: { delta in moveRule(rule.id, by: delta) },
                    onRemove: { recipe.rules.removeAll { $0.id == rule.id } })
            }
            Menu("Add Rule") {
                Button("Exclude a value") { recipe.rules.append(SearchRule(kind: .exclude(""))) }
                Button("Replace text") { recipe.rules.append(SearchRule(kind: .replace(from: "-", to: " "))) }
            }
            .fixedSize()
        } header: {
            Text("Rules")
        } footer: {
            Text("Run top to bottom over every value the parts gathered, before case and quoting — move a rule to change the order. Exclude drops a value equal to the text, ignoring case, never a substring, so “on” cannot touch “On Stage”. Replace changes every occurrence; leave the right side empty to remove the text.")
        }
    }

    private func moveRule(_ id: UUID, by delta: Int) {
        var rules = recipe.rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        recipe.rules = rules
    }

    // MARK: Preview

    private var sample: SearchSubject? {
        let name = sampleFileName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : SearchSubject(fileName: name, tags: sampleTags)
    }

    private var previewSection: some View {
        Section {
            LabeledContent("Sample file name") {
                TextField("A file name to preview against", text: $sampleFileName)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(11))
            }
            if let sample {
                let string = SearchStringBuilder.string(recipe: recipe, subject: sample)
                LabeledContent("Search string") {
                    Text(string.isEmpty ? "(nothing)" : string)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(string.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let terms = SearchStringBuilder.bookmarkTerms(recipe: recipe, subject: sample)
                LabeledContent("Bookmark values") {
                    Text(terms.isEmpty ? "(none)" : terms.joined(separator: " · "))
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Type a sample file name to see the string it would make.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let missing = SearchStringBuilder.missingCategoryIDs(in: recipe, known: Set(categories.map(\.id)))
            if !missing.isEmpty {
                Label(
                    "\(missing.count) tag part\(missing.count == 1 ? " names" : "s name") a category this library no longer has; it contributes nothing.",
                    systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("The sample starts as the library's first file; type any name over it. The tags in the preview are the first item's.")
        }
    }

    // MARK: Firefox

    private var firefoxSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                Text("Applies on this Mac, whichever library is open.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            LabeledContent("Firefox profile") {
                HStack {
                    TextField("Profile folder", text: $firefoxProfile)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                    Button("Detect") {
                        if let found = FirefoxProfiles.detect() {
                            firefoxProfile = found.path
                        } else {
                            statusText = "No Firefox profile list found under \(FirefoxProfiles.defaultRoot.path)."
                        }
                    }
                    Button("Choose…") { chooseProfile() }
                }
            }
            LabeledContent("Web search URL") {
                TextField("https://duckduckgo.com/?q={query}", text: $webSearchURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 320)
            }
            Text("The bookmarks come from the profile's places.sqlite, read from a copy. The web search opens in Firefox, or the default browser when Firefox is not installed; {query} stands for the string.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Firefox")
        }
    }

    private func chooseProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FirefoxProfiles.defaultRoot.appendingPathComponent("Profiles")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        firefoxProfile = url.path
    }

    // MARK: Load and apply

    /// Read everything from where it is stored — on a library change,
    /// and on Revert.
    private func load() {
        statusText = nil
        let settings = AppSettingsStore.shared.current
        firefoxProfile = settings.firefoxProfilePath ?? ""
        webSearchURL = settings.webSearchURL
        guard let id = selectedLibraryID, let library = try? model.library(for: id) else {
            formats = .empty
            savedFormats = .empty
            selectedFormatID = nil
            categories = []
            sampleFileName = ""
            sampleTags = []
            return
        }
        do {
            formats = try library.searchFormats()
            savedFormats = formats
            if !formats.formats.contains(where: { $0.id == selectedFormatID }) {
                selectedFormatID = formats.defaultFormat?.id
            }
            categories = try library.vocabulary().map(\.category)
            let first = try library.writer.read { try MediaItem.order(sql: "relativePath").fetchOne($0) }
            let subject = try first.flatMap { try library.searchSubject(for: $0.id) }
            sampleFileName = subject?.fileName ?? ""
            sampleTags = subject?.tags ?? []
        } catch {
            statusText = "Could not read the library: \(error)"
        }
    }

    /// Write the draft: the formats to the library, the Firefox fields
    /// to settings.json.
    private func apply() {
        if let id = selectedLibraryID, let library = try? model.library(for: id), formats != savedFormats {
            do {
                try library.setSearchFormats(formats)
                savedFormats = formats
            } catch {
                statusText = "Could not save the formats: \(error)"
                return
            }
        }
        let profile = firefoxProfile.trimmingCharacters(in: .whitespaces)
        let url = webSearchURL.trimmingCharacters(in: .whitespaces)
        AppSettingsStore.shared.update {
            $0.firefoxProfilePath = profile.isEmpty ? nil : profile
            $0.webSearchURL = url.isEmpty ? AppSettings.defaultWebSearchURL : url
        }
        firefoxProfile = profile
        webSearchURL = url.isEmpty ? AppSettings.defaultWebSearchURL : url
        statusText = "Applied."
    }
}

/// One part as a row: its kind's controls, then case and quoting for
/// the kinds that take them, then move and remove.
private struct PartRow: View {
    @Binding var part: SearchPart
    let categories: [TagCategory]
    let isFirst: Bool
    let isLast: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(kindName)
                .font(Theme.ui(11, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            switch part.kind {
            case .literal:
                TextField("Text, used as typed", text: literalText)
                    .textFieldStyle(.roundedBorder)
            case .fileName:
                Toggle("Extension", isOn: includesExtension).toggleStyle(.checkbox)
                Toggle("Split at _", isOn: splitsPieces).toggleStyle(.checkbox)
                formatPickers
            case .tags:
                Picker("", selection: categoryID) {
                    Text("All categories").tag(UUID?.none)
                    ForEach(categories) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                TextField("joiner", text: joiner)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .help("Between several tags of the category")
                formatPickers
            }
            Spacer(minLength: 0)
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private var formatPickers: some View {
        Group {
            Picker("", selection: $part.format.letterCase) {
                ForEach(SearchLetterCase.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 110)
            Picker("", selection: $part.format.quoting) {
                ForEach(SearchQuoting.allCases, id: \.self) { Text("Quote: \($0.displayName)").tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
    }

    private var kindName: String {
        switch part.kind {
        case .literal: "Text"
        case .fileName: "File name"
        case .tags: "Tags"
        }
    }

    private var literalText: Binding<String> {
        Binding(
            get: { if case .literal(let text) = part.kind { text } else { "" } },
            set: { part.kind = .literal($0) })
    }

    private var includesExtension: Binding<Bool> {
        Binding(
            get: { if case .fileName(let ext, _) = part.kind { ext } else { false } },
            set: { on in
                if case .fileName(_, let split) = part.kind { part.kind = .fileName(includesExtension: on, splitsPieces: split) }
            })
    }

    private var splitsPieces: Binding<Bool> {
        Binding(
            get: { if case .fileName(_, let split) = part.kind { split } else { false } },
            set: { on in
                if case .fileName(let ext, _) = part.kind { part.kind = .fileName(includesExtension: ext, splitsPieces: on) }
            })
    }

    private var categoryID: Binding<UUID?> {
        Binding(
            get: { if case .tags(let id, _) = part.kind { id } else { nil } },
            set: { id in
                if case .tags(_, let joiner) = part.kind { part.kind = .tags(categoryID: id, joiner: joiner) }
            })
    }

    private var joiner: Binding<String> {
        Binding(
            get: { if case .tags(_, let joiner) = part.kind { joiner } else { " " } },
            set: { text in
                if case .tags(let id, _) = part.kind { part.kind = .tags(categoryID: id, joiner: text) }
            })
    }
}

/// One rule as a row: Exclude with its value, or Replace with its two
/// sides, then move and remove.
private struct RuleRow: View {
    @Binding var rule: SearchRule
    let isFirst: Bool
    let isLast: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(kindName)
                .font(Theme.ui(11, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            switch rule.kind {
            case .exclude:
                TextField("A value never to add — a prefix like sdg", text: excludeText)
                    .textFieldStyle(.roundedBorder)
            case .replace:
                TextField("Replace", text: replaceFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("with (empty removes)", text: replaceTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Spacer(minLength: 0)
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(isFirst)
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(isLast)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
    }

    private var kindName: String {
        switch rule.kind {
        case .exclude: "Exclude"
        case .replace: "Replace"
        }
    }

    private var excludeText: Binding<String> {
        Binding(
            get: { if case .exclude(let text) = rule.kind { text } else { "" } },
            set: { rule.kind = .exclude($0) })
    }

    private var replaceFrom: Binding<String> {
        Binding(
            get: { if case .replace(let from, _) = rule.kind { from } else { "" } },
            set: { from in if case .replace(_, let to) = rule.kind { rule.kind = .replace(from: from, to: to) } })
    }

    private var replaceTo: Binding<String> {
        Binding(
            get: { if case .replace(_, let to) = rule.kind { to } else { "" } },
            set: { to in if case .replace(let from, _) = rule.kind { rule.kind = .replace(from: from, to: to) } })
    }
}
