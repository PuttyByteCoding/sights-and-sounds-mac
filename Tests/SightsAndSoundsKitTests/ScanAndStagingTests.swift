import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Scanning produces a list and writes nothing; importing takes a named
/// list and applies what was staged with it.
@Suite struct ScanAndStagingTests {

    /// A fixture whose "source root" is a real temporary directory, so
    /// the scan enumerates actual files. Synthetic throughout.
    private func makeSource(
        files: [String], in library: LibraryDatabase
    ) throws -> (Source, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-scan-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let source = Source(name: "Scan", rootPath: root.path)
        try library.writer.write { try source.insert($0) }
        return (source, root)
    }

    @Test func scanListsAndClassifiesWithoutWriting() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(
            files: ["shows/a.mp4", "shows/b.mp4", "misc/c.flac", "notes/readme.txt"],
            in: library)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await MediaScanner.scan(source: source, library: library)
        #expect(outcome.candidates.map(\.relativePath)
            == ["misc/c.flac", "shows/a.mp4", "shows/b.mp4"])
        #expect(outcome.newCount == 3)
        #expect(outcome.knownCount == 0)
        // Nothing entered the library.
        #expect(try library.mediaItems(matching: MediaFilter(), kinds: .all).isEmpty)
    }

    /// The histogram answers the question the file list provokes: why
    /// are there 38 files in this folder and 36 here?
    @Test func theScanReportsWhatItDidNotList() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(
            files: ["a.mp4", "b.m2ts", "c.m2ts", "notes.txt"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await MediaScanner.scan(source: source, library: library)
        #expect(outcome.skippedByExtension["m2ts"] == 2)
        #expect(outcome.skippedByExtension["txt"] == 1)
    }

    /// Already-imported rows stay in the list, marked — seeing that a
    /// folder is 1-of-2 known is the information.
    @Test func knownFilesAreListedNotHidden() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(files: ["a.mp4", "b.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4").insert(db)
        }

        let outcome = try await MediaScanner.scan(source: source, library: library)
        #expect(outcome.candidates.count == 2)
        #expect(outcome.knownCount == 1)
        #expect(outcome.candidates.first { $0.relativePath == "a.mp4" }?.isKnown == true)
    }

    @Test func foldersCarryTheirNewAndKnownSplit() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(
            files: ["shows/a.mp4", "shows/b.mp4", "misc/c.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        try await library.writer.write { db in
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "shows/a.mp4").insert(db)
        }

        let folders = try await MediaScanner.scan(source: source, library: library).folders()
        #expect(folders.map(\.path) == ["misc", "shows"])
        #expect(folders.first { $0.path == "shows" }?.new == 1)
        #expect(folders.first { $0.path == "shows" }?.known == 1)
    }

    // MARK: - Import from a list

    @Test func importInsertsOnlyTheNamedFiles() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(files: ["a.mp4", "b.mp4", "c.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)

        _ = try await ImportJob.enqueue(
            on: runner, sourceID: source.id, relativePaths: ["a.mp4", "c.mp4"])
        try await runner.runPending()

        let names = try library.mediaItems(matching: MediaFilter(), kinds: .all).map(\.fileName)
        #expect(Set(names) == ["a.mp4", "c.mp4"])
    }

    /// Staging applies through the ordinary write paths — a single-select
    /// category still replaces rather than accumulating.
    @Test func stagingAppliesToEveryInsertedRow() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let category = TagCategory(name: "Band")
        try library.createCategory(category)
        let tag = try library.ensureTag(named: "Ash & Ember", inCategory: category.id)
        let (source, root) = try makeSource(files: ["a.mp4", "b.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)

        _ = try await ImportJob.enqueue(
            on: runner, sourceID: source.id,
            staging: ImportStaging(tagIDs: [tag.id], clearsNeedsReview: true))
        try await runner.runPending()

        let items = try library.mediaItems(matching: MediaFilter(required: [.tag(tag.id)]), kinds: .all)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.needsReview })
    }

    /// The list is a snapshot; the disk is not. The guard lives in the
    /// write, not in the UI's opinion of it.
    @Test func importStaysIdempotentEvenWhenTheListIsStale() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scan")
        let (source, root) = try makeSource(files: ["a.mp4"], in: library)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)

        _ = try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["a.mp4"])
        try await runner.runPending()
        _ = try await ImportJob.enqueue(on: runner, sourceID: source.id, relativePaths: ["a.mp4"])
        try await runner.runPending()

        #expect(try library.mediaItems(matching: MediaFilter(), kinds: .all).count == 1)
    }

    // MARK: - Boxes

    @Test func importBoxesRoundTripPerLibrary() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Boxes")
        let categoryID = UUID()
        try library.setImportBoxes([
            ImportBox(source: .category(categoryID), sticky: true, stickyTagIDs: [UUID()]),
        ])
        let loaded = try library.importBoxes()
        #expect(loaded.count == 1)
        #expect(loaded[0].categoryID == categoryID)
        #expect(loaded[0].sticky)
        #expect(loaded[0].stickyTagIDs.count == 1)
    }

    @Test func aLibraryWithNoBoxesConfiguredHasNone() throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Boxes")
        #expect(try library.importBoxes().isEmpty)
    }
}
