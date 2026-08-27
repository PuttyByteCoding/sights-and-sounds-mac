import GRDB
import SwiftUI
import SightsAndSoundsKit

/// Get Info, for a library: identity, contents, coverage, configuration
/// — facts and jump-offs, not a second editor (Settings is where things
/// change; the one exception is the library's name, whose explicit
/// rename belongs here). Aggregates load off the main actor: a
/// properties window must never beachball on a big library.
struct LibraryPropertiesView: View {
    @Environment(AppModel.self) private var app
    let libraryID: UUID

    private struct SourceLine: Identifiable, Sendable {
        var id: UUID
        var name: String
        var rootPath: String
        var enabled: Bool
        var itemCount: Int
    }

    private struct Snapshot: Sendable {
        var info: LibraryInfo?
        var filePath: String?
        var fileBytes: Int64
        var migrations: Int
        var videoCount = 0
        var audioCount = 0
        var embeddedClips = 0
        var exportedClips = 0
        var mediaBytes: Int64 = 0
        var sources: [SourceLine] = []
        var hashed = 0
        var hashable = 0
        var thumbnailsOnDisk = 0
        var thumbnailFailures = 0
        var fingerprints = 0
        var ocrItems = 0
        var pendingDuplicates = 0
        var categories = 0
        var tags = 0
        var fields = 0
    }

    @State private var snapshot: Snapshot?
    @State private var errorText: String?
    @State private var draftName = ""
    @State private var statusText: String?

    var body: some View {
        Group {
            if let snapshot {
                form(snapshot)
            } else if let errorText {
                ContentUnavailableView(
                    "Could Not Read Library", systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle(snapshot?.info?.name ?? "Library Properties")
        .task { await load() }
    }

    @ViewBuilder
    private func form(_ snapshot: Snapshot) -> some View {
        Form {
            Section("Identity") {
                LabeledContent("Name") {
                    HStack {
                        TextField("Name", text: $draftName)
                            .frame(minWidth: 180)
                        Button("Rename") { rename() }
                            .disabled(
                                draftName.trimmingCharacters(in: .whitespaces).isEmpty
                                    || draftName == snapshot.info?.name)
                    }
                }
                if let info = snapshot.info {
                    LabeledContent("Library ID") {
                        Text(info.libraryID.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Created", value: info.createdAt.formatted(
                        date: .abbreviated, time: .shortened))
                }
                if let path = snapshot.filePath {
                    LabeledContent("File") {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)])
                        } label: {
                            Text(path).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help("Reveal in Finder")
                    }
                }
                LabeledContent(
                    "Library file size",
                    value: ByteCountFormatter.string(
                        fromByteCount: snapshot.fileBytes, countStyle: .file))
                LabeledContent("Schema migrations applied", value: "\(snapshot.migrations)")
                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Contents") {
                LabeledContent("Video items", value: "\(snapshot.videoCount)")
                LabeledContent("Audio items", value: "\(snapshot.audioCount)")
                LabeledContent(
                    "Clips",
                    value: "\(snapshot.embeddedClips) embedded · \(snapshot.exportedClips) exported")
                LabeledContent(
                    "Total media size",
                    value: ByteCountFormatter.string(
                        fromByteCount: snapshot.mediaBytes, countStyle: .file))
                ForEach(snapshot.sources) { source in
                    LabeledContent(source.name) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(source.itemCount) items\(source.enabled ? "" : " · disabled")")
                            Text(source.rootPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            // The numbers the background workers chase — "is it done
            // churning." Reported from the same sources the jobs use to
            // decide work, never re-derived differently.
            Section("Coverage") {
                LabeledContent("Content hashes", value: "\(snapshot.hashed) of \(snapshot.hashable)")
                LabeledContent("Thumbnails on disk") {
                    Text(snapshot.thumbnailFailures > 0
                        ? "\(snapshot.thumbnailsOnDisk) (\(snapshot.thumbnailFailures) failed)"
                        : "\(snapshot.thumbnailsOnDisk)")
                }
                LabeledContent("Audio fingerprints", value: "\(snapshot.fingerprints)")
                LabeledContent("Items with scanned text", value: "\(snapshot.ocrItems)")
                LabeledContent("Pending duplicate pairs", value: "\(snapshot.pendingDuplicates)")
            }

            Section("Configuration") {
                LabeledContent(
                    "Vocabulary",
                    value: "\(snapshot.categories) categories · \(snapshot.tags) tags · \(snapshot.fields) fields")
                Text("View the full configuration in Settings → Tag Category Configuration; edit categories from the library window's Categories button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let info = snapshot.info {
                    LabeledContent("Import extensions") {
                        Text(info.videoExtensionsOverride == nil
                            && info.audioExtensionsOverride == nil
                            ? "Inheriting app-wide"
                            : "Overridden for this library")
                    }
                }
            }

            Section("History") {
                LabeledContent("Last opened") {
                    Text(app.libraries.first { $0.id == libraryID }?.lastOpenedAt?
                        .formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { backUp() }
            }
        }
        .formStyle(.grouped)
    }

    private func load() async {
        do {
            let library = try app.library(for: libraryID)
            let ref = app.libraries.first { $0.id == libraryID }
            let loaded = try await Task.detached(priority: .userInitiated) { () -> Snapshot in
                var snapshot = Snapshot(
                    info: try library.info(),
                    filePath: ref?.filePath,
                    fileBytes: ref.flatMap {
                        try? FileManager.default.attributesOfItem(atPath: $0.filePath)[.size]
                            as? Int64
                    } ?? 0,
                    migrations: try library.appliedMigrations().count)

                let base = snapshot
                let counted: Snapshot = try await library.writer.read { db -> Snapshot in
                    var filled = base
                    func count(_ sql: String) throws -> Int {
                        try Int.fetchOne(db, sql: sql) ?? 0
                    }
                    filled.videoCount = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE kind = 0 AND clipExported = 0")
                    filled.audioCount = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE kind = 1 AND clipExported = 0")
                    filled.embeddedClips = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE isClip AND NOT isExportedClip AND clipExported = 0")
                    filled.exportedClips = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE isExportedClip")
                    filled.mediaBytes = try Int64.fetchOne(
                        db,
                        sql: "SELECT COALESCE(SUM(fileSize), 0) FROM mediaItem WHERE parentMediaItemID IS NULL")
                        ?? 0
                    filled.hashed = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE contentHash IS NOT NULL")
                    filled.hashable = try count(
                        "SELECT COUNT(*) FROM mediaItem WHERE parentMediaItemID IS NULL AND clipExported = 0")
                    filled.thumbnailFailures = try count(
                        "SELECT COUNT(*) FROM thumbnailState WHERE failureMessage IS NOT NULL")
                    filled.fingerprints = try count("SELECT COUNT(*) FROM audioFingerprint")
                    filled.ocrItems = try count(
                        "SELECT COUNT(DISTINCT mediaItemID) FROM ocrTextLine")
                    filled.categories = try count("SELECT COUNT(*) FROM tagCategory")
                    filled.tags = try count("SELECT COUNT(*) FROM tag")
                    filled.fields = try count("SELECT COUNT(*) FROM fieldDefinition")
                    let sources = try Source.order(sql: "name").fetchAll(db)
                    filled.sources = try sources.map { source in
                        SourceLine(
                            id: source.id, name: source.name, rootPath: source.rootPath,
                            enabled: source.enabled,
                            itemCount: try Int.fetchOne(
                                db,
                                sql: "SELECT COUNT(*) FROM mediaItem WHERE sourceID = ? AND clipExported = 0",
                                arguments: [source.id]) ?? 0)
                    }
                    return filled
                }
                snapshot = counted

                snapshot.pendingDuplicates = try library.pendingCandidates().count
                // Disk state IS the thumbnail truth (the sweep's rule).
                if let info = snapshot.info {
                    let dir = ThumbnailStore.root
                        .appendingPathComponent(info.libraryID.uuidString, isDirectory: true)
                    snapshot.thumbnailsOnDisk = (try? FileManager.default
                        .contentsOfDirectory(atPath: dir.path).count) ?? 0
                }
                return snapshot
            }.value
            snapshot = loaded
            draftName = loaded.info?.name ?? ""
        } catch {
            errorText = "\(error)"
        }
    }

    /// The one edit Properties owns: renames are explicit acts, and this
    /// is their home. Updates the identity row and the registry.
    private func rename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let library = try app.library(for: libraryID)
            try library.writer.write { db in
                try db.execute(sql: "UPDATE libraryInfo SET name = ?", arguments: [name])
            }
            try app.appDatabase?.register(library)
            app.refresh()
            statusText = "Renamed to “\(name)”."
            Task { await load() }
        } catch {
            statusText = "Rename failed: \(error)"
        }
    }

    private func backUp() {
        do {
            let library = try app.library(for: libraryID)
            let url = try library.backup(into: LibraryDatabase.defaultBackupDirectory())
            statusText = "Backed up to \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            statusText = "Backup failed: \(error)"
        }
    }
}
