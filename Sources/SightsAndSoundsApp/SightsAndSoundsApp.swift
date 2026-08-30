import SwiftUI
import SightsAndSoundsKit

/// Early app shell: the library registry and the new-library flow (name →
/// template → review → create). The browse workspace arrives in Phase 3.
@main
struct SightsAndSoundsApp: App {
    @State private var model = AppModel()

    static let pickerWindowID = "picker"

    init() {
        // Before the first view draws, so nothing renders a frame in the
        // system face and reflows once Archivo arrives.
        Fonts.registerAll()

        // Tooltips: the macOS default initial delay (~1.5 s) makes every
        // `.help()` feel unresponsive. Shorter, but deliberately not
        // instant so tooltips don't flash while mousing across a toolbar.
        // Registered, not set — an explicit user default still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

        // Run as a REGULAR app even when launched as a bare executable
        // (`swift run`): without a bundle, macOS treats the process as
        // background — windows draw and clicks land, but keyboard focus
        // never arrives (it stays with Terminal). Harmless when launched
        // from a real .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // The picker is a DIALOG, not the app's root window (spec 01): it
        // appears at launch and from File ▸ Open Library…, and goes away
        // as soon as a library is chosen. A `Window`, not a `WindowGroup`
        // — there is only ever one, and choosing twice should return to
        // the one already up rather than stack a second.
        Window("Sights and Sounds", id: Self.pickerWindowID) {
            LibraryPickerView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .newItem) {
                OpenLibraryCommand()
                    .environment(model)
            }
        }

        // One library per window — several can be open at once, each backed
        // by its own LibraryDatabase (locked decision 02).
        WindowGroup(id: "library", for: LibraryRef.ID.self) { $libraryID in
            if let libraryID {
                LibraryWindowView(libraryID: libraryID)
                    .environment(model)
                    // The picker's OPEN badge, its Bring Forward, and the
                    // summary cache all key off this.
                    .onAppear { model.libraryWindowAppeared(libraryID) }
                    .onDisappear { model.libraryWindowDisappeared(libraryID) }
                    .focusedSceneValue(\.openLibraryID, libraryID)
            }
        }

        // Auxiliary workspaces — Categories, Duplicates, Move History,
        // Reorganize, Validation — one window per (library, surface).
        // Windows, not sheets: draggable, resizable, usable beside the
        // grid.
        WindowGroup(id: "aux", for: AuxWindowRequest.self) { $request in
            if let request {
                AuxiliaryWindowView(request: request)
                    .environment(model)
            }
        }

        // Get Info for one library — facts, coverage, jump-offs.
        WindowGroup(id: "properties", for: LibraryRef.ID.self) { $libraryID in
            if let libraryID {
                LibraryPropertiesView(libraryID: libraryID)
                    .environment(model)
            }
        }

        // One dashboard across every library (workers run once and
        // service them all).
        Window("Background Tasks", id: "tasks") {
            BackgroundTasksView()
                .environment(model)
        }

        Window("Log", id: "log") {
            LogView()
        }

        Settings {
            SettingsView()
                .environment(model)
        }
        // Minimums are a floor, not the size — without this the Settings
        // window tracks its content's ideal size and can't be resized.
        .windowResizability(.contentMinSize)
    }
}

/// App-level state: the registry store, opened once.
@Observable @MainActor
final class AppModel {
    let appDatabase: AppDatabase?
    var libraries: [LibraryRef] = []
    var loadError: String? {
        didSet {
            if let loadError { AppLog.shared.error("app", loadError) }
        }
    }

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
        if let appDatabase {
            AppSettingsStore.shared.migrateLegacySkip(from: appDatabase)
        }
    }

    func refresh() {
        guard let appDatabase else { return }
        do { libraries = try appDatabase.libraries() } catch {
            loadError = "Could not read libraries: \(error)"
        }
    }

    // MARK: - The library picker

    /// Which way the picker was reached. It decides three things: the
    /// title, whether cancel reads Quit, and whether the placement band
    /// appears — because only from the menu is there a window to replace.
    enum PickerContext { case launch, menu }

    var pickerContext: PickerContext = .launch
    /// The library whose window "This window" would close. Nil from
    /// launch, and nil from the menu when no library window has focus.
    var pickerOriginLibraryID: UUID?

    /// Libraries with a window on screen. Drives the `OPEN` badge, the
    /// Bring Forward primary, and the default selection landing on
    /// something you can actually open.
    private(set) var openLibraryIDs: Set<UUID> = []

    /// Offline source counts, for open libraries only. A shut library
    /// cannot be asked whether its drives are plugged in without opening
    /// it and stat-ing every root — the slow case the cached summary
    /// exists to avoid.
    private(set) var offlineSourceCounts: [UUID: Int] = [:]

    func libraryWindowAppeared(_ libraryID: UUID) {
        openLibraryIDs.insert(libraryID)
        refreshOfflineCount(for: libraryID)
    }

    func libraryWindowDisappeared(_ libraryID: UUID) {
        openLibraryIDs.remove(libraryID)
        offlineSourceCounts[libraryID] = nil
        // The one moment the counts are both current and free: the handle
        // is open and the user is done with it.
        cacheSummary(for: libraryID)
    }

    /// Snapshot a library's counts into the registry so the picker can
    /// show them without opening the file. Off the main actor — a
    /// `SUM(fileSize)` over a large library is not a main-thread read.
    ///
    /// The handle is deliberately left open: a job may still be running
    /// against it, and the runner is the owner of that lifetime.
    func cacheSummary(for libraryID: UUID) {
        guard let appDatabase, let library = try? library(for: libraryID) else { return }
        Task.detached(priority: .utility) {
            do {
                try appDatabase.cacheSummary(try library.summary(), for: libraryID)
            } catch {
                // Never surfaced: a stale row summary is a cosmetic loss,
                // and this runs as a window is going away.
                AppLog.shared.warning("app", "Could not cache the library summary: \(error)")
            }
            await MainActor.run { self.refresh() }
        }
    }

    /// Re-observe every open library's sources. Called when the picker
    /// appears — the badge has to be right at the moment it is read, and
    /// a drive can be unplugged while the dialog is not up.
    func refreshOpenLibraryStatus() {
        for id in openLibraryIDs { refreshOfflineCount(for: id) }
    }

    private func refreshOfflineCount(for libraryID: UUID) {
        guard let library = try? library(for: libraryID) else { return }
        Task.detached(priority: .utility) {
            let access: any FileAccess = LiveFileAccess()
            guard let sources = try? await library.writer.read({ try Source.fetchAll($0) }) else { return }
            let offline = sources.filter { $0.enabled && !$0.isOnline(using: access) }.count
            await MainActor.run {
                // Only for a library still open: the window may have closed
                // while this was in flight, and a stale count would badge a
                // row the spec says cannot be badged.
                guard self.openLibraryIDs.contains(libraryID) else { return }
                self.offlineSourceCounts[libraryID] = offline
            }
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

    /// App-wide background-task pause, session-only. Runners created
    /// while paused start paused; resuming kicks each runner's drain so
    /// held queues empty without waiting for the next signal.
    private(set) var tasksPaused = false

    func setTasksPaused(_ paused: Bool) {
        tasksPaused = paused
        for runner in runners.values {
            Task {
                await runner.setPaused(paused)
                if !paused { _ = try? await runner.runPending() }
            }
        }
    }

    func runner(for libraryID: UUID) throws -> JobRunner {
        if let existing = runners[libraryID] { return existing }
        let runner = JobRunner(library: try library(for: libraryID))
        runners[libraryID] = runner
        Task {
            await runner.setPaused(tasksPaused)
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
            await runner.register(OcrJob.self)
            await runner.register(JoinJob.self)
            await runner.register(ReorganizeJob.self)
            await runner.register(WritebackJob.self)
            await runner.register(RestoreTagsJob.self)
            await runner.register(ValidationJob.self)
        }
        return runner
    }

    /// Restore a library file from a backup: verify the backup opens,
    /// close the live handle, archive the current file beside the backups
    /// (never destroyed), copy the backup into place, drop caches so the
    /// next open is fresh. Caller has confirmed and closed windows.
    func restoreLibrary(id: UUID, from backupURL: URL) throws {
        guard let ref = libraries.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try LibraryDatabase.verifyBackup(at: backupURL)

        if let open = try? library(for: id) { try? open.close() }
        runners[id] = nil
        openHandles[id] = nil

        let currentURL = URL(fileURLWithPath: ref.filePath)
        let archiveDir = LibraryDatabase.defaultBackupDirectory()
            .appendingPathComponent(ref.name, isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let archive = archiveDir.appendingPathComponent(
            "\(ref.name) pre-restore \(Date().timeIntervalSince1970).sqlite")
        if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.moveItem(at: currentURL, to: archive)
        }
        try FileManager.default.copyItem(at: backupURL, to: currentURL)
        refresh()
    }

    /// Forget a library: close its open handle, drop its runner, delete
    /// the registry row. The library FILE on disk is untouched — Add
    /// Existing… re-registers it, reconciled by the library's own id.
    /// Caller has confirmed and closed the library's windows.
    func removeLibrary(id: UUID) {
        if let open = openHandles[id] { try? open.close() }
        runners[id] = nil
        openHandles[id] = nil
        do {
            try appDatabase?.unregister(id)
        } catch {
            loadError = "Could not remove the library from the list: \(error)"
        }
        refresh()
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

/// The library window that has focus, published to the menu bar so File ▸
/// Open Library… knows which window "This window" would replace. A scene
/// value, not a window value: the command lives on the menu bar, which is
/// outside every window.
struct OpenLibraryFocusKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var openLibraryID: UUID? {
        get { self[OpenLibraryFocusKey.self] }
        set { self[OpenLibraryFocusKey.self] = newValue }
    }
}

/// File ▸ Open Library… — the second way into the picker.
///
/// It reads the focused library window so the dialog can name what "This
/// window" would close. With no library window focused there is nothing
/// to replace, so the placement band stays away and the dialog behaves as
/// it does at launch, apart from cancel still meaning cancel.
struct OpenLibraryCommand: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.openLibraryID) private var focusedLibraryID

    var body: some View {
        Button("Open Library…") {
            model.pickerContext = .menu
            model.pickerOriginLibraryID = focusedLibraryID
            model.refresh()
            openWindow(id: SightsAndSoundsApp.pickerWindowID)
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}

/// Identifies one item to play, plus the filtered listing it came from
/// so the player's arrows can walk it. Setting one on a BrowseModel
/// swaps that library window over to the embedded player.
struct PlayerRequest: Codable, Hashable {
    var libraryID: UUID
    var itemID: UUID
    var playlist: [UUID] = []
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
        if category.displayStyle != .search { parts.append(category.displayStyle.displayName.lowercased()) }
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


struct LogWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Log", systemImage: "text.alignleft") {
            openWindow(id: "log")
        }
        .help("The app's debug log — what happened, and why")
    }
}

struct TasksWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Background Tasks", systemImage: "list.bullet.rectangle") {
            openWindow(id: "tasks")
        }
        .help("Imports, hashing, thumbnails and operations — across all libraries")
    }
}


/// Register a library file that already exists — a migrated library, a
/// restored backup, or a file from another machine. Verified to open and
/// migrate before it's registered; reconciliation by the library's own id
/// means re-adding is never a duplicate.
struct AddExistingLibraryButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Add Existing…", systemImage: "folder.badge.plus") { add() }
            .help("Register a library file — e.g. one the migrator produced")
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.title = "Add Existing Library"
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let library = try LibraryDatabase.open(at: url)
            // A migrated/created library is already named; a bare file gets
            // its filename as identity.
            try library.ensureInfo(name: url.deletingPathExtension().lastPathComponent)
            guard let appDatabase = model.appDatabase else { return }
            try appDatabase.register(library)
            model.refresh()
        } catch {
            model.loadError = "Could not add library: \(error)"
        }
    }
}
