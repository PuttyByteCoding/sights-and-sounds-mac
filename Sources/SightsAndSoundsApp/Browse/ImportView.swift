import GRDB
import SwiftUI
import SightsAndSoundsKit

/// The import surface: every source with its reachability, item count
/// and last scan, per-source and scan-all actions with live progress,
/// the effective file-type lists the scan will honor, and the recent
/// import history. Opens as an auxiliary window — usable beside the
/// grid while a long scan runs.
struct ImportView: View {
    @Environment(BrowseModel.self) private var model

    @State private var itemCounts: [UUID: Int] = [:]
    @State private var online: [UUID: Bool] = [:]
    @State private var history: [JobRecord] = []
    @State private var videoExtensions: [String] = []
    @State private var audioExtensions: [String] = []
    @State private var hasOverride = false
    @State private var loadGeneration = 0

    private var anyImportRunning: Bool { !model.importStatus.isEmpty }

    var body: some View {
        Form {
            Section {
                if model.sources.isEmpty {
                    Text("No sources yet — add a folder to import from.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    ImportSourceRow(
                        source: source,
                        itemCount: itemCounts[source.id],
                        isOnline: online[source.id],
                        status: model.importStatus[source.id],
                        onScan: { model.importSource(source) })
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") { addFolder() }
                        .help("Register a folder as a source and scan it now")
                    Spacer()
                    Button("Scan All Sources", systemImage: "arrow.clockwise") {
                        for source in model.sources where source.enabled {
                            model.importSource(source)
                        }
                    }
                    .disabled(model.sources.isEmpty || anyImportRunning)
                    .help("Scan every enabled source for new files")
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Scans are additive: new files are imported, known files are "
                    + "skipped, and files missing from disk are never removed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                extensionRow(label: "Video", extensions: videoExtensions)
                extensionRow(label: "Audio", extensions: audioExtensions)
            } header: {
                Text("File Types")
            } footer: {
                Text(hasOverride
                    ? "This library overrides the app-wide lists — edit in Settings › Library Import."
                    : "App-wide lists — edit in Settings › Import, or override per library in Settings › Library Import.")
                    .foregroundStyle(.secondary)
            }

            Section("Recent Imports") {
                if history.isEmpty {
                    Text("No imports recorded yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(history) { record in
                    ImportHistoryRow(record: record)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 420)
        .task { await reload() }
        .onChange(of: model.sources) { Task { await reload() } }
        // A finished scan empties its importStatus slot — refresh the
        // counts and history the moment the last one settles.
        .onChange(of: anyImportRunning) { _, running in
            if !running { Task { await reload() } }
        }
    }

    private func extensionRow(label: String, extensions: [String]) -> some View {
        LabeledContent(label) {
            Text(extensions.isEmpty ? "none" : extensions.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Source"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let source = model.addSource(at: url) {
            model.importSource(source)
        }
    }

    /// Counts, reachability, history and the effective extension lists —
    /// gathered off the main actor, published behind a generation guard.
    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let library = model.library
        let sources = model.sources
        let appSettings = AppSettingsStore.shared.current

        struct Loaded: Sendable {
            var counts: [UUID: Int] = [:]
            var online: [UUID: Bool] = [:]
            var history: [JobRecord] = []
            var video: [String] = []
            var audio: [String] = []
            var hasOverride = false
        }
        let loaded = await Task.detached { () -> Loaded in
            var result = Loaded()
            do {
                // Sync read on purpose — the async overload's closure
                // inference is ambiguous to the CI toolchain (Xcode 16),
                // and this whole task is already off the main actor.
                try library.writer.read { db in
                    let rows = try Row.fetchAll(
                        db, sql: "SELECT sourceID, COUNT(*) AS c FROM mediaItem GROUP BY sourceID")
                    for row in rows {
                        if let id = row["sourceID"] as UUID? {
                            result.counts[id] = row["c"]
                        }
                    }
                    result.history = try JobRecord
                        .filter(sql: "kind = ?", arguments: [ImportJob.kind])
                        .order(sql: "createdAt DESC")
                        .limit(12)
                        .fetchAll(db)
                    let info = try LibraryInfo.fetchOne(db)
                    result.hasOverride = info?.videoExtensionsOverride != nil
                        || info?.audioExtensionsOverride != nil
                    result.video = (info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
                        ?? Set(appSettings.videoExtensions.map { $0.lowercased() })).sorted()
                    result.audio = (info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
                        ?? Set(appSettings.audioExtensions.map { $0.lowercased() })).sorted()
                }
            } catch {
                // Leave the partial result — the rows render what loaded.
            }
            let fileAccess = LiveFileAccess()
            for source in sources {
                result.online[source.id] = source.isOnline(using: fileAccess)
            }
            return result
        }.value

        guard generation == loadGeneration else { return }
        itemCounts = loaded.counts
        online = loaded.online
        history = loaded.history
        videoExtensions = loaded.video
        audioExtensions = loaded.audio
        hasOverride = loaded.hasOverride
    }
}

private struct ImportSourceRow: View {
    let source: Source
    let itemCount: Int?
    let isOnline: Bool?
    let status: String?
    let onScan: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isOnline == false ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .help(isOnline == false ? "Offline — the folder is unreachable" : "Online")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                    if !source.enabled {
                        Text("disabled")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(source.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.rootPath)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(itemCount ?? 0) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let lastSeen = source.lastSeenAt {
                    Text("scanned \(lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .frame(minWidth: 70, alignment: .trailing)
            } else {
                Button("Scan", systemImage: "arrow.clockwise", action: onScan)
                    .disabled(!source.enabled || isOnline == false)
                    .help(source.enabled
                        ? "Scan this source for new files"
                        : "Enable the source to scan it")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ImportHistoryRow: View {
    let record: JobRecord

    private var stateLabel: (text: String, color: Color) {
        switch record.state {
        case .queued: ("queued", .secondary)
        case .running: ("running", .blue)
        case .succeeded: ("done", .green)
        case .failed: ("failed", .orange)
        case .cancelled: ("cancelled", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stateLabel.text)
                .font(.caption)
                .foregroundStyle(stateLabel.color)
                .frame(width: 64, alignment: .leading)
            Text(record.summary ?? record.error ?? "—")
                .foregroundStyle(record.error == nil ? .primary : .secondary)
                .lineLimit(2)
            Spacer()
            Text((record.finishedAt ?? record.createdAt)
                .formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
