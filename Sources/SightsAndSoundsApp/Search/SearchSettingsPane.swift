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
    /// The library holds formats this version cannot decode. The editor
    /// shows none, and Apply must not write that "none" over them.
    @State private var storedFormatsUnreadable = false
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
                if formats.formats.count > 1 {
                    overviewSection
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
                if storedFormatsUnreadable {
                    Button("Replace Stored Formats") { apply(replacingUnreadable: true) }
                        .help("Discard the formats this version cannot read and save the ones shown here")
                }
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
                Button("Duplicate Format") {
                    guard let source = formats.formats.first(where: { $0.id == selectedFormatID }) else { return }
                    let copy = source.duplicate(named: "\(source.name) copy")
                    formats.formats.append(copy)
                    selectedFormatID = copy.id
                }
                .disabled(selectedFormatID == nil)
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
            Text("Several formats, one library. The player's Search panel shows every format's string and copies one on a click; the menu commands use the one marked here, which the panel's ⌘⇧C marker can also move. Duplicate Format copies the picked one to start another from.")
        }
    }

    // MARK: Overview

    /// Every format's configuration at once — one line per part and
    /// per rule, and the sample's string — so two formats can be read
    /// side by side without switching the picker between them.
    private var overviewSection: some View {
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        return Section {
            ForEach(formats.formats) { format in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(format.name.isEmpty ? "Untitled" : format.name)
                            .font(Theme.ui(12, .semibold))
                        if formats.defaultFormat?.id == format.id {
                            Text("⌘⇧C")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.Accent.amber)
                        }
                        if format.id == selectedFormatID {
                            Text("editing")
                                .font(Theme.ui(9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { selectedFormatID = format.id }
                            .buttonStyle(.link)
                            .font(Theme.ui(11))
                    }
                    if let sample {
                        let string = SearchStringBuilder.string(recipe: format, subject: sample)
                        Text(string.isEmpty ? "(nothing for the sample)" : string)
                            .font(Theme.mono(11))
                            .foregroundStyle(string.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(format.parts) { part in
                        Text("• " + part.summary(categoryNames: names))
                            .font(Theme.ui(11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(format.rules) { rule in
                        Text("→ " + rule.summary)
                            .font(Theme.ui(11))
                            .foregroundStyle(.secondary)
                    }
                    if format.parts.isEmpty, format.rules.isEmpty {
                        Text("(empty)").font(Theme.ui(11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("All formats")
        } footer: {
            Text("Every format as configured — parts with •, rules with → in the order they run — against the sample. Edit picks one above; Duplicate Format starts a new one from the one picked.")
        }
    }

    // MARK: Parts and rules

    private var partsSection: some View {
        Section {
            RecipeParts(recipe: recipeBinding, categories: categories)
        } header: {
            Text("Parts")
        } footer: {
            Text("Top to bottom, joined with spaces — drag the ≡ handle to reorder. Text is used as typed; file name and tag parts take the case and quoting beside them.")
        }
    }

    private var rulesSection: some View {
        Section {
            RecipeRules(recipe: recipeBinding, preview: sample)
        } header: {
            Text("Rules")
        } footer: {
            Text("Run top to bottom over every value the parts gathered, before case and quoting — drag the ≡ handle to change the order. Exclude removes its text wherever it appears, ignoring case — or all but the first or the last occurrence, when asked; a value left empty is dropped. Replace changes every occurrence, matching case; leave the right side empty to remove the text. Either can take its text as a regular expression (Regex): Exclude then removes the matches, and a Replace's right side may name groups as $1, $2; a pattern that does not compile does nothing. Split breaks each value at its separator — and at the capitals inside a run, when ticked — keeping every piece or only the first or last, and the rules below work on what it kept.")
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
            storedFormatsUnreadable = false
            selectedFormatID = nil
            categories = []
            sampleFileName = ""
            sampleTags = []
            return
        }
        do {
            formats = try library.searchFormats()
            savedFormats = formats
            storedFormatsUnreadable = try library.storedSearchFormatsAreUnreadable()
            if storedFormatsUnreadable {
                statusText = "This library's search formats were saved in a form this version cannot read. They are untouched, and Apply will not replace them."
            }
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
    private func apply(replacingUnreadable: Bool = false) {
        if let id = selectedLibraryID, let library = try? model.library(for: id),
           formats != savedFormats || replacingUnreadable {
            do {
                try library.setSearchFormats(formats, replacingUnreadable: replacingUnreadable)
                savedFormats = formats
                storedFormatsUnreadable = false
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
