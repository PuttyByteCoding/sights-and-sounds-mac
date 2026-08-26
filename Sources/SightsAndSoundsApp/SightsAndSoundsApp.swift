import SwiftUI
import SightsAndSoundsKit

/// Early app shell: the library registry and the new-library flow (name →
/// template → review → create). The browse workspace arrives in Phase 3.
@main
struct SightsAndSoundsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryListView()
                .environment(model)
        }

        // One library per window — several can be open at once, each backed
        // by its own LibraryDatabase (locked decision 02).
        WindowGroup(id: "library", for: LibraryRef.ID.self) { $libraryID in
            if let libraryID {
                LibraryWindowView(libraryID: libraryID)
                    .environment(model)
            }
        }

        WindowGroup(id: "player", for: PlayerRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(model)
            }
        }

        // One dashboard across every library (workers run once and
        // service them all).
        Window("Background Tasks", id: "tasks") {
            BackgroundTasksView()
                .environment(model)
        }
    }
}

/// App-level state: the registry store, opened once.
@Observable @MainActor
final class AppModel {
    let appDatabase: AppDatabase?
    var libraries: [LibraryRef] = []
    var loadError: String?

    init() {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("SightsAndSounds", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            appDatabase = try AppDatabase.open(at: dir.appendingPathComponent("App.sqlite"))
        } catch {
            appDatabase = nil
            loadError = "Could not open the app store: \(error)"
        }
        refresh()
    }

    func refresh() {
        guard let appDatabase else { return }
        do { libraries = try appDatabase.libraries() } catch {
            loadError = "Could not read libraries: \(error)"
        }
    }

    // One open handle per library, shared by every window and the player.
    private var openHandles: [UUID: LibraryDatabase] = [:]

    func library(for id: UUID) throws -> LibraryDatabase {
        if let open = openHandles[id] { return open }
        guard let ref = libraries.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let library = try LibraryDatabase.open(at: URL(fileURLWithPath: ref.filePath))
        openHandles[id] = library
        try? appDatabase?.touchLastOpened(id)
        return library
    }

    // ONE job runner per library, shared by windows and the dashboard —
    // cancellation only works against the runner that owns the job.
    private var runners: [UUID: JobRunner] = [:]

    func runner(for libraryID: UUID) throws -> JobRunner {
        if let existing = runners[libraryID] { return existing }
        let runner = JobRunner(library: try library(for: libraryID))
        runners[libraryID] = runner
        Task {
            await runner.register(ImportJob.self)
            await runner.register(ContentHashJob.self)
            await runner.register(ThumbnailBatchJob.self)
            await runner.register(HashDuplicateSweepJob.self)
            await runner.register(FingerprintCaptureJob.self)
            await runner.register(FingerprintMatchSweepJob.self)
            await runner.register(ClipExportJob.self)
            await runner.register(RemuxJob.self)
            await runner.register(EncodeJob.self)
            await runner.register(BlockRemovalJob.self)
        }
        return runner
    }

    /// The signal: wake the library's workers. Sleeps-until-woken, never
    /// polls — imports finishing and volumes mounting call this. Work is
    /// decided from disk/db state inside the jobs; duplicate signals
    /// collapse via enqueueUnlessPending.
    func signalMaintenance(for libraryID: UUID) {
        Task {
            do {
                let runner = try runner(for: libraryID)
                _ = try await runner.enqueueUnlessPending(ContentHashJob.self)
                _ = try await runner.enqueueUnlessPending(
                    ThumbnailBatchJob.self,
                    payload: JSONEncoder().encode(ThumbnailBatchJob.Payload(libraryID: libraryID)))
                // Duplicates ride the same signal: hash pairs after hashing,
                // fingerprints after capture, matches after both.
                _ = try await runner.enqueueUnlessPending(HashDuplicateSweepJob.self)
                _ = try await runner.enqueueUnlessPending(FingerprintCaptureJob.self)
                _ = try await runner.enqueueUnlessPending(FingerprintMatchSweepJob.self)
                try await runner.runPending()
            } catch {
                loadError = "Maintenance failed: \(error)"
            }
        }
    }
}

/// Identifies one item to play, across window boundaries, plus the
/// filtered listing it came from so the player's arrows can walk it.
struct PlayerRequest: Codable, Hashable {
    var libraryID: UUID
    var itemID: UUID
    var playlist: [UUID] = []
}

struct LibraryListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).padding()
            }
            if model.libraries.isEmpty {
                ContentUnavailableView(
                    "No Libraries",
                    systemImage: "books.vertical",
                    description: Text("Create your first library to get started."))
            } else {
                List(model.libraries) { library in
                    LibraryRow(library: library)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("Sights and Sounds")
        .toolbar {
            Button("New Library…", systemImage: "plus") { showingNewLibrary = true }
            DemoLibraryButton()
            TasksWindowButton()
        }
        .sheet(isPresented: $showingNewLibrary) {
            NewLibraryFlow()
                .environment(model)
        }
    }
}

/// Name + template → category review → create. The review step edits a
/// `LibraryPlan`; nothing exists on disk until Create.
struct NewLibraryFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var libraryName = ""
    @State private var template: LibraryTemplate = .concerts
    @State private var plan: LibraryPlan?
    @State private var creationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let planBinding = Binding($plan) {
                reviewStep(planBinding)
            } else {
                setupStep
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
    }

    private var setupStep: some View {
        Form {
            TextField("Library name", text: $libraryName, prompt: Text("Concerts"))
            Picker("Template", selection: $template) {
                ForEach(LibraryTemplate.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            Text(template.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Review Categories") {
                    let name = libraryName.isEmpty ? template.displayName : libraryName
                    plan = template.plan(named: name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func reviewStep(_ plan: Binding<LibraryPlan>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review — \(plan.wrappedValue.name)")
                .font(.title2)
            Text("Rename or exclude anything. Nothing is written until Create.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                Section("Categories") {
                    ForEach(plan.categories) { $category in
                        HStack {
                            Toggle("", isOn: $category.include).labelsHidden()
                            TextField("Name", text: $category.name)
                                .disabled(!category.include)
                            Spacer()
                            Text(categorySummary(category))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.wrappedValue.itemFields.isEmpty {
                    Section("Fields") {
                        ForEach(plan.itemFields) { $field in
                            HStack {
                                Toggle("", isOn: $field.include).labelsHidden()
                                TextField("Name", text: $field.name)
                                    .disabled(!field.include)
                                Spacer()
                                Text(field.dataType.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let creationError {
                Text(creationError).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Back") { self.plan = nil }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create(plan.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func categorySummary(_ category: PlannedCategory) -> String {
        var parts: [String] = [category.allowMultiple ? "multiple" : "single"]
        if category.displayAsCheckboxes { parts.append("checkboxes") }
        if !category.tags.isEmpty { parts.append("\(category.tags.count) tags") }
        if let field = category.writebackField { parts.append("→ \(field)") }
        return parts.joined(separator: " · ")
    }

    private func create(_ plan: LibraryPlan) {
        let panel = NSSavePanel()
        panel.title = "Create Library"
        panel.nameFieldStringValue = plan.name + ".sqlite"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryCreator.create(at: url, plan: plan, registerIn: model.appDatabase)
            model.refresh()
            dismiss()
        } catch {
            creationError = "\(error)"
        }
    }
}


struct LibraryRow: View {
    @Environment(\.openWindow) private var openWindow
    let library: LibraryRef

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(library.name).font(.headline)
                Text(library.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { openWindow(id: "library", value: library.id) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openWindow(id: "library", value: library.id) }
    }
}


/// Builds a complete demo library — vocabulary, items, and tiny synthesized
/// media files — so every pipeline (thumbnails, waveforms, scrub previews,
/// playback, filters) runs on data that is fake by construction.
struct DemoLibraryButton: View {
    @Environment(AppModel.self) private var model
    @State private var busyText: String?

    var body: some View {
        if let busyText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busyText).font(.caption)
            }
        } else {
            Button("Create Demo Library…", systemImage: "sparkles") { create() }
                .help("A fake concert collection with generated media files")
        }
    }

    private func create() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the demo library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Create Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        busyText = "Generating demo library…"
        let appDatabase = model.appDatabase
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                let libraryURL = folder.appendingPathComponent("Demo Concerts.sqlite")
                let mediaRoot = folder.appendingPathComponent("Demo Media", isDirectory: true)
                let library = try LibraryDatabase.open(at: libraryURL)
                try library.ensureInfo(name: "Demo Concerts")
                let source = Source(name: "Demo Media", rootPath: mediaRoot.path)

                try await DemoLibrarySeeder.seed(library: library, source: source) { path, kind in
                    let fileURL = mediaRoot.appendingPathComponent(path)
                    // Variant from the path bytes: deterministic, no shared
                    // counter to capture.
                    let variant = Int(path.utf8.reduce(UInt64(0)) { $0 &+ UInt64($1) } % 8)
                    switch kind {
                    case .video:
                        try await DemoMediaFactory.writeVideo(to: fileURL, variant: variant)
                    case .audio:
                        try DemoMediaFactory.writeAudio(to: fileURL, variant: variant)
                    }
                    let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]
                    return (size as? Int64) ?? 0
                }
                if let appDatabase { _ = try await MainActor.run { try appDatabase.register(library) } }
            } catch {
                failure = "\(error)"
            }
            let message = failure
            await MainActor.run {
                busyText = nil
                if let message { model.loadError = "Demo library failed: \(message)" }
                model.refresh()
            }
        }
    }
}


struct TasksWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Background Tasks", systemImage: "list.bullet.rectangle") {
            openWindow(id: "tasks")
        }
    }
}
