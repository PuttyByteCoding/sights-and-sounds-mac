import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Settings › Search String (spec 17, decision 7): the library's recipe
/// as rows — kind, source, formatting — with exclusions, replacements
/// and a live preview; and, app-wide, the Firefox profile and the web
/// search URL. The page is a draft: the preview follows every edit,
/// and Apply is what writes it — to the library and to settings.json.
struct SearchSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedLibraryID: UUID?
    @State private var recipe = SearchRecipe.empty
    /// What the library holds. Apply moves the draft here.
    @State private var savedRecipe = SearchRecipe.empty
    @State private var categories: [TagCategory] = []
    /// The preview's file name: the library's first item's to start,
    /// then whatever is typed — a name with the shape in question, not
    /// whichever file sorts first. The tags stay the first item's.
    @State private var sampleFileName = ""
    @State private var sampleTags: [SearchSubjectTag] = []
    @State private var statusText: String?
    @State private var newExclusion = ""
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
                Text("One string per video, built from its file name and tags in the order below. ⌘⇧C copies it, ⌘⇧F searches the web with it, ⌘⇧B searches Firefox's bookmarks for its values. Nothing takes effect until Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selectedLibraryID != nil {
                partsSection
                exclusionsSection
                replacementsSection
                previewSection
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
        return (selectedLibraryID != nil && recipe != savedRecipe)
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

    // MARK: Parts

    private var partsSection: some View {
        Section {
            if recipe.parts.isEmpty {
                Text("No parts yet. Add one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($recipe.parts) { $part in
                PartRow(
                    part: $part, categories: categories,
                    isFirst: recipe.parts.first?.id == part.id,
                    isLast: recipe.parts.last?.id == part.id,
                    onMove: { delta in move(part.id, by: delta) },
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

    private func move(_ id: UUID, by delta: Int) {
        guard let index = recipe.parts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard recipe.parts.indices.contains(target) else { return }
        recipe.parts.swapAt(index, target)
    }

    // MARK: Exclusions and replacements

    private var exclusionsSection: some View {
        Section {
            ForEach(recipe.exclusions, id: \.self) { value in
                HStack {
                    Text(value).font(Theme.mono(11.5))
                    Spacer()
                    Button { recipe.exclusions.removeAll { $0 == value } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("A value never to add — a prefix like sdg", text: $newExclusion)
                    .onSubmit(addExclusion)
                Button("Add", action: addExclusion)
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Exclusions")
        } footer: {
            Text("Whole values only, ignoring case: a file-name piece or a tag equal to one of these is left out. Never a substring, so “on” cannot touch “On Stage”.")
        }
    }

    private func addExclusion() {
        let value = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !recipe.exclusions.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
        else { return }
        recipe.exclusions.append(value)
        newExclusion = ""
    }

    private var replacementsSection: some View {
        Section {
            ForEach($recipe.replacements) { $replacement in
                HStack(spacing: 8) {
                    TextField("Replace", text: $replacement.from)
                        .frame(width: 120)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("with", text: $replacement.to)
                        .frame(width: 120)
                    Spacer()
                    Button { recipe.replacements.removeAll { $0.id == replacement.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Replacement") {
                recipe.replacements.append(SearchReplacement(from: "-", to: " "))
            }
        } header: {
            Text("Replacements")
        } footer: {
            Text("Applied to every value before anything else, in order, every occurrence — “-” to a space keeps a hyphenated name searchable.")
        }
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
            recipe = .empty
            savedRecipe = .empty
            categories = []
            sampleFileName = ""
            sampleTags = []
            return
        }
        do {
            recipe = try library.searchRecipe()
            savedRecipe = recipe
            categories = try library.vocabulary().map(\.category)
            let first = try library.writer.read { try MediaItem.order(sql: "relativePath").fetchOne($0) }
            let subject = try first.flatMap { try library.searchSubject(for: $0.id) }
            sampleFileName = subject?.fileName ?? ""
            sampleTags = subject?.tags ?? []
        } catch {
            statusText = "Could not read the library: \(error)"
        }
    }

    /// Write the draft: the recipe to the library, the Firefox fields
    /// to settings.json.
    private func apply() {
        if let id = selectedLibraryID, let library = try? model.library(for: id), recipe != savedRecipe {
            do {
                try library.setSearchRecipe(recipe)
                savedRecipe = recipe
            } catch {
                statusText = "Could not save the recipe: \(error)"
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
