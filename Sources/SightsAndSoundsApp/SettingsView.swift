import SwiftUI
import SightsAndSoundsKit

/// The Settings scene (⌘,): app-level configuration backed by
/// `settings.json`. Per-library data (tag key bindings, category
/// configuration) stays in the library files; the Vocabulary pane does
/// JSON export/import instead of relocating storage.
struct SettingsView: View {
    var body: some View {
        // App-wide panes first, then per-library — and every pane opens
        // with a ScopeHeader saying which it is (#66).
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ImportSettingsPane()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
            PlaybackSettingsPane()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            JobsSettingsPane()
                .tabItem { Label("Jobs", systemImage: "gearshape.2") }
            VocabularySettingsPane()
                .tabItem { Label("Tag Category Configuration", systemImage: "tag") }
            LibraryImportSettingsPane()
                .tabItem { Label("Library Import", systemImage: "square.and.arrow.down.on.square") }
        }
        // A minimum, not a fixed width — the Settings window resizes
        // like any other (#73). The infinity maximums matter: the
        // Settings scene sizes its window to the content's ideal size,
        // and rigid content leaves nothing to grow into (#101).
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .padding(.bottom, 8)
        .background(SettingsWindowConfigurator())
    }
}

/// The Settings scene doesn't reliably honor `windowResizability` —
/// AppKit can leave `.resizable` out of the panel's style mask even
/// with flexible content (#101). This reaches the hosting NSWindow
/// once attached, forces the resizable bit, and names a frame
/// autosave so the chosen size and position persist across opens.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AttachView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AttachView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.setFrameAutosaveName("SASSettingsWindow")
        }
    }
}

/// The scope line at the top of every pane — a setting's reach should be
/// readable before its controls are. Presentation only; the storage
/// split (settings.json vs the library file) is long-standing.
private struct ScopeHeader: View {
    enum Scope { case app, library }
    let scope: Scope

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: scope == .app ? "laptopcomputer" : "books.vertical")
            Text(scope == .app
                ? "Applies to this Mac — every library. Stored in settings.json."
                : "Applies to the selected library only. Stored in its library file.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Reads once, writes through the store on change.
@MainActor
private func bindSetting<T>(
    _ keyPath: WritableKeyPath<AppSettings, T>, refresh: @escaping () -> Void
) -> Binding<T> {
    Binding(
        get: { AppSettingsStore.shared.current[keyPath: keyPath] },
        set: { newValue in
            AppSettingsStore.shared.update { $0[keyPath: keyPath] = newValue }
            refresh()
        })
}

private struct PathSettingRow: View {
    let title: String
    let help: String
    let keyPath: WritableKeyPath<AppSettings, String?>
    let defaultLabel: String
    @State private var tick = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(AppSettingsStore.shared.current[keyPath: keyPath] ?? defaultLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(help)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    AppSettingsStore.shared.update { $0[keyPath: keyPath] = url.path }
                    tick.toggle()
                }
                if AppSettingsStore.shared.current[keyPath: keyPath] != nil {
                    Button("Reset") {
                        AppSettingsStore.shared.update { $0[keyPath: keyPath] = nil }
                        tick.toggle()
                    }
                }
            }
        }
        .id(tick)
    }
}

private struct GeneralSettingsPane: View {
    var body: some View {
        Form {
            ScopeHeader(scope: .app)
            PathSettingRow(
                title: "Backups",
                help: "Where Back Up Now writes dated library copies",
                keyPath: \.backupDirectory,
                defaultLabel: "Application Support (default)")
            PathSettingRow(
                title: "Log files",
                help: "When set, the debug log also appends to a daily file here",
                keyPath: \.logDirectory,
                defaultLabel: "off — in-app log and Console only")
            PathSettingRow(
                title: "Thumbnail cache",
                help: "Where grid thumbnails are stored",
                keyPath: \.thumbnailDirectory,
                defaultLabel: "Caches (default)")
            Text("Settings live in settings.json in Application Support — hand-editable; missing keys fall back to defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ImportSettingsPane: View {
    @State private var video = AppSettingsStore.shared.current.videoExtensions.joined(separator: ", ")
    @State private var audio = AppSettingsStore.shared.current.audioExtensions.joined(separator: ", ")

    var body: some View {
        Form {
            ScopeHeader(scope: .app)
            Section("File types imported into libraries") {
                TextField("Video extensions", text: $video)
                    .onSubmit { save() }
                TextField("Audio extensions", text: $audio)
                    .onSubmit { save() }
                HStack {
                    Button("Save") { save() }
                    Button("Reset to Defaults") {
                        video = AppSettings.defaultVideoExtensions.joined(separator: ", ")
                        audio = AppSettings.defaultAudioExtensions.joined(separator: ", ")
                        save()
                    }
                    Spacer()
                }
                Text("Comma-separated, case-insensitive. Applies to the next import; existing items are untouched. A library can override these lists in the Library Import tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        func parse(_ raw: String) -> [String] {
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }
        AppSettingsStore.shared.update {
            $0.videoExtensions = parse(video)
            $0.audioExtensions = parse(audio)
        }
    }
}

private struct PlaybackSettingsPane: View {
    @State private var skip = AppSettingsStore.shared.current.skip
    @State private var startVideosMuted = AppSettingsStore.shared.current.startVideosMuted
    @State private var loopVideos = AppSettingsStore.shared.current.loopVideos
    @State private var infoBar = AppSettingsStore.shared.current.infoBar
    @State private var videoAnchor = AppSettingsStore.shared.current.videoAnchor

    var body: some View {
        Form {
            ScopeHeader(scope: .app)
            Section("Sound") {
                Toggle("Start videos muted", isOn: $startVideosMuted)
                Text("Audio items are never muted. Applies to the next item you play; M or the speaker button unmutes during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Video position") {
                Picker("Anchor", selection: $videoAnchor) {
                    ForEach(VideoAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.displayName).tag(anchor)
                    }
                }
                Text("Where the video sits when it doesn't fill the player area. Applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Looping") {
                Toggle("Loop videos", isOn: $loopVideos)
                Text("Restart from the beginning at the end of the item. Applies to the next item you play; L or the repeat button toggles it during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Info bar under the video") {
                Toggle("Position (\u{201C}x of y\u{201D})", isOn: $infoBar.showsPosition)
                Toggle("Tags", isOn: $infoBar.showsTags)
                Toggle("Favorite star", isOn: $infoBar.showsFavorite)
                Toggle("Save a Copy button", isOn: $infoBar.showsDownload)
                Text("The bar hides entirely when everything is off. Applies to the next item you play.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Seek distances (seconds)") {
                row("Keys 1 / 3 — short", back: $skip.key1Seconds, forward: $skip.key3Seconds)
                row("Keys 4 / 6 — medium", back: $skip.key4Seconds, forward: $skip.key6Seconds)
                row("Keys 7 / 9 — long", back: $skip.key7Seconds, forward: $skip.key9Seconds)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1/4/7 seek back · 3/6/9 forward (top row, shifted, or numpad)")
                    Text("Applies to the next item you play.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Fixed keys") {
                keyMapGrid
            }
        }
        .formStyle(.grouped)
        .onChange(of: skip) {
            AppSettingsStore.shared.update { $0.skip = skip }
        }
        .onChange(of: startVideosMuted) {
            AppSettingsStore.shared.update { $0.startVideosMuted = startVideosMuted }
        }
        .onChange(of: loopVideos) {
            AppSettingsStore.shared.update { $0.loopVideos = loopVideos }
        }
        .onChange(of: infoBar) {
            AppSettingsStore.shared.update { $0.infoBar = infoBar }
        }
        .onChange(of: videoAnchor) {
            AppSettingsStore.shared.update { $0.videoAnchor = videoAnchor }
        }
    }

    private func row(_ label: String, back: Binding<Double>, forward: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("back", value: back, format: .number)
                    .frame(width: 64)
                Text("back ·")
                TextField("forward", value: forward, format: .number)
                    .frame(width: 64)
                Text("forward")
            }
        }
    }

    /// One key → one meaning per line; a wrapped paragraph split key
    /// names from what they do.
    private var keyMapGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            keyRow("5 / Space", "Play / pause")
            keyRow("0", "Start (a clip's in-point)")
            keyRow("8", "Near the end")
            keyRow("F R D W", "Favorite · needs review · deletion · playback issue")
            keyRow("T", "Tag panel")
            keyRow("M", "Mute")
            keyRow("L", "Loop")
            keyRow("{ }", "Hide block: open · close")
            keyRow("⌃{ ⌃}", "Clip: in-point · out-point")
            keyRow("← →", "Previous / next item")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func keyRow(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).monospaced()
            Text(action)
        }
    }
}

private struct VocabularySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedLibraryID: UUID?
    @State private var statusText: String?
    @State private var showConfiguration = false

    var body: some View {
        Form {
            ScopeHeader(scope: .library)
            Section("Tag Category Configuration") {
                Picker("Library", selection: $selectedLibraryID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.libraries) { library in
                        Text(library.name).tag(UUID?.some(library.id))
                    }
                }
                HStack {
                    Button("View Configuration…") { showConfiguration = true }
                        .disabled(selectedLibraryID == nil)
                    Button("Export Configuration…") { exportVocabulary() }
                        .disabled(selectedLibraryID == nil)
                    Button("Import Configuration…") { importVocabulary() }
                        .disabled(selectedLibraryID == nil)
                }
                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
                Text("The file is the same shape the creation templates use. Import is additive: existing categories keep their configuration; missing categories, tags, aliases and fields are created. Nothing is deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showConfiguration) {
            if let id = selectedLibraryID, let library = try? model.library(for: id) {
                ConfigurationSheet(
                    library: library,
                    libraryName: model.libraries.first { $0.id == id }?.name ?? "Library")
            }
        }
    }

    private func exportVocabulary() {
        guard let id = selectedLibraryID, let library = try? model.library(for: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vocabulary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VocabularyIO.exportJSON(from: library).write(to: url)
            statusText = "Exported to \(url.lastPathComponent)"
        } catch {
            statusText = "Export failed: \(error)"
        }
    }

    private func importVocabulary() {
        guard let id = selectedLibraryID, let library = try? model.library(for: id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let outcome = try VocabularyIO.importJSON(try Data(contentsOf: url), into: library)
            statusText = "Imported: \(outcome.categoriesCreated) categories, \(outcome.tagsCreated) tags, \(outcome.fieldsCreated) fields created (\(outcome.skippedExisting) already present)"
        } catch {
            statusText = "Import failed: \(error)"
        }
    }
}

private struct JobsSettingsPane: View {
    @State private var interval = AppSettingsStore.shared.current.ocrSampleIntervalSeconds
    @State private var budget = AppSettingsStore.shared.current.ocrBudgetSecondsPerRun

    var body: some View {
        Form {
            ScopeHeader(scope: .app)
            Section("OCR text scanning") {
                LabeledContent("Sample a frame every") {
                    TextField("seconds", value: $interval, format: .number)
                        .frame(width: 64)
                    Text("seconds")
                }
                LabeledContent("Per-run budget") {
                    TextField("seconds", value: $budget, format: .number)
                        .frame(width: 64)
                    Text("seconds of media")
                }
                Text("Applies to the next scan; scans resume where they left off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: interval) { AppSettingsStore.shared.update { $0.ocrSampleIntervalSeconds = interval } }
        .onChange(of: budget) { AppSettingsStore.shared.update { $0.ocrBudgetSecondsPerRun = budget } }
    }
}

/// Read-only, human-readable view of a library's tag category
/// configuration — the "let me see what's in there" affordance. Editing
/// stays in the library window's Categories sheet.
private struct ConfigurationSheet: View {
    let library: LibraryDatabase
    let libraryName: String
    @Environment(\.dismiss) private var dismiss

    private struct Snapshot: Sendable {
        var categories: [(category: TagCategory, tags: [Tag])]
        var aliases: [UUID: [String]]
        var fields: [FieldDefinition]
    }

    @State private var snapshot: Snapshot?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let snapshot {
                    // A List, virtualized — a migrated category can hold
                    // thousands of tags.
                    List {
                        ForEach(snapshot.categories, id: \.category.id) { entry in
                            Section {
                                ForEach(entry.tags) { tag in
                                    tagRow(tag, aliases: snapshot.aliases[tag.id] ?? [])
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(entry.category.name) — \(entry.tags.count) tags")
                                    Text(summary(of: entry.category))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        }
                        if !snapshot.fields.isEmpty {
                            Section("Fields") {
                                ForEach(snapshot.fields) { field in
                                    LabeledContent(field.name) {
                                        Text(String(describing: field.dataType))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else if let errorText {
                    ContentUnavailableView(
                        "Could Not Read Configuration",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorText))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(libraryName).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 480)
        .task { await load() }
    }

    private func tagRow(_ tag: Tag, aliases: [String]) -> some View {
        HStack(spacing: 6) {
            Text(tag.name)
            if !aliases.isEmpty {
                Text("— also \(aliases.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            if tag.hiddenByDefault {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Hidden by default — items carrying this tag are suppressed unless the filter references it")
            }
            Spacer()
        }
        .font(.callout)
    }

    /// The category's configuration as one readable line, mirroring the
    /// category manager's summary vocabulary.
    private func summary(of category: TagCategory) -> String {
        var parts = [category.allowMultiple ? "multiple per item" : "single per item"]
        if category.displayAsCheckboxes { parts.append("checkboxes") }
        if category.isDefaultFocus { parts.append("default focus") }
        if category.hiddenFromBrowse { parts.append("hidden from browse") }
        switch category.textFormat {
        case .noFormatting: break
        case .titleCase: parts.append("Title Case")
        case .allLowercase: parts.append("lowercase")
        case .allUppercase: parts.append("UPPERCASE")
        }
        if category.separatorsToSpaces { parts.append("separators → spaces") }
        if let field = category.writebackField { parts.append("writes back → \(field)") }
        if let label = category.sectionLabel, !label.isEmpty { parts.append("section “\(label)”") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let library = library
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let vocabulary = try library.vocabulary()
                let aliases = Dictionary(
                    grouping: try await library.writer.read { try TagAlias.fetchAll($0) },
                    by: \.tagID
                ).mapValues { $0.map(\.alias) }
                let fields = try await library.writer.read {
                    try FieldDefinition.order(sql: "name").fetchAll($0)
                }
                return Snapshot(categories: vocabulary, aliases: aliases, fields: fields)
            }.value
            snapshot = loaded
        } catch {
            errorText = "\(error)"
        }
    }
}

/// Per-library import-extension override (#69). Inherit is the strong
/// default; the override toggle makes replace-vs-inherit a visible
/// choice, never an empty-field ambiguity. The override REPLACES the
/// app-wide list — a lossless-audio library can DROP extensions.
private struct LibraryImportSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedLibraryID: UUID?
    @State private var overrideEnabled = false
    @State private var video = ""
    @State private var audio = ""
    @State private var statusText: String?

    var body: some View {
        Form {
            ScopeHeader(scope: .library)
            Section("Imported file extensions") {
                Picker("Library", selection: $selectedLibraryID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.libraries) { library in
                        Text(library.name).tag(UUID?.some(library.id))
                    }
                }
                Toggle("Override for this library", isOn: $overrideEnabled)
                    .disabled(selectedLibraryID == nil)
                if overrideEnabled {
                    TextField("Video extensions", text: $video)
                    TextField("Audio extensions", text: $audio)
                } else {
                    Text("Using the app-wide lists from the Import tab.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save") { save() }
                        .disabled(selectedLibraryID == nil)
                    if let statusText {
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("The override replaces the app-wide lists — it can drop extensions, not just add. Comma-separated, case-insensitive; applies to the next import. Stored in the library file, so it travels with the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedLibraryID) { loadCurrent() }
    }

    private func loadCurrent() {
        statusText = nil
        guard let id = selectedLibraryID,
              let library = try? model.library(for: id),
              let info = try? library.info()
        else {
            overrideEnabled = false
            video = ""
            audio = ""
            return
        }
        overrideEnabled = info.videoExtensionsOverride != nil
            || info.audioExtensionsOverride != nil
        video = (info.videoExtensionsOverride
            ?? AppSettingsStore.shared.current.videoExtensions).joined(separator: ", ")
        audio = (info.audioExtensionsOverride
            ?? AppSettingsStore.shared.current.audioExtensions).joined(separator: ", ")
    }

    private func save() {
        guard let id = selectedLibraryID, let library = try? model.library(for: id) else { return }
        func parse(_ raw: String) -> [String] {
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }
        do {
            if overrideEnabled {
                try library.setExtensionOverrides(video: parse(video), audio: parse(audio))
                statusText = "Override saved."
            } else {
                try library.setExtensionOverrides(video: nil, audio: nil)
                statusText = "Inheriting the app-wide lists."
            }
        } catch {
            statusText = "Save failed: \(error)"
        }
    }
}
