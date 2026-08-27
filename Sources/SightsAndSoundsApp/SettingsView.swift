import SwiftUI
import SightsAndSoundsKit

/// The Settings scene (⌘,): app-level configuration backed by
/// `settings.json`. Per-library data (tag key bindings, category
/// configuration) stays in the library files; the Vocabulary pane does
/// JSON export/import instead of relocating storage.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ImportSettingsPane()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
            PlaybackSettingsPane()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            VocabularySettingsPane()
                .tabItem { Label("Vocabulary", systemImage: "tag") }
            JobsSettingsPane()
                .tabItem { Label("Jobs", systemImage: "gearshape.2") }
        }
        .frame(width: 560)
        .padding(.bottom, 8)
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
                Text("Comma-separated, case-insensitive. Applies to the next import; existing items are untouched.")
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

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Start videos muted", isOn: $startVideosMuted)
                Text("Audio items are never muted. Applies to the next item you play; M or the speaker button unmutes during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Looping") {
                Toggle("Loop videos", isOn: $loopVideos)
                Text("Restart from the beginning at the end of the item. Applies to the next item you play; L or the repeat button toggles it during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Seek distances (seconds)") {
                row("Keys 1 / 3 — short", back: $skip.key1Seconds, forward: $skip.key3Seconds)
                row("Keys 4 / 6 — medium", back: $skip.key4Seconds, forward: $skip.key6Seconds)
                row("Keys 7 / 9 — long", back: $skip.key7Seconds, forward: $skip.key9Seconds)
                Text("1/4/7 seek back, 3/6/9 forward — top row, shifted, or numpad. Applies to the next item you play. The rest of the key map is fixed: 5/Space play-pause, 0 start, 8 near end, F/R/D/W flags, T tags, { } blocks, ⌃{ ⌃} clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}

private struct VocabularySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedLibraryID: UUID?
    @State private var statusText: String?

    var body: some View {
        Form {
            Section("Category configuration — export / import as JSON") {
                Picker("Library", selection: $selectedLibraryID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.libraries) { library in
                        Text(library.name).tag(UUID?.some(library.id))
                    }
                }
                HStack {
                    Button("Export Vocabulary…") { exportVocabulary() }
                        .disabled(selectedLibraryID == nil)
                    Button("Import Vocabulary…") { importVocabulary() }
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
