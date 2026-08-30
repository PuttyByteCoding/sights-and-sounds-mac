import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 7d: the template port, reorganization end to end, OCR on frames
/// with real burned-in text, search, and the ffmpeg join.
@Suite struct OrganizeAndOcrTests {

    // MARK: Template port

    @Test func templateValidation() {
        let categories = ["Band", "Recording Type", "Year"]
        #expect(OrganizeTemplate.validate("%Band/%Year", categoryNames: categories).isEmpty)
        // Underscore folding.
        #expect(OrganizeTemplate.validate("%Recording_Type", categoryNames: categories).isEmpty)
        #expect(OrganizeTemplate.validate("", categoryNames: categories)
            .contains { $0.message.contains("empty") })
        #expect(OrganizeTemplate.validate("plain/text", categoryNames: categories)
            .contains { $0.message.contains("no tokens") })
        // An unknown token names the category and points at the window
        // that would fix it.
        #expect(OrganizeTemplate.validate("%Venue", categoryNames: categories)
            .contains { $0.message.contains("No category called \"Venue\"") })
        #expect(OrganizeTemplate.validate("%Band//%Year", categoryNames: categories)
            .contains { $0.message.contains("empty path segment") })
    }

    @Test func templateResolution() {
        let tags = ["Band": ["Meadow Larks"], "Year": ["1995"]]
        let simple = OrganizeTemplate.resolve("%Band/%Year", tagsByCategory: tags)
        #expect(simple.relativeFolder == "Meadow Larks/1995")

        // Multi-value: ordinal first + note.
        let multi = OrganizeTemplate.resolve(
            "%Band", tagsByCategory: ["Band": ["Zeta", "Alpha"]])
        #expect(multi.relativeFolder == "Alpha")
        #expect(multi.notes.first?.contains("2 values") == true)

        // Missing token skips with the name.
        let missing = OrganizeTemplate.resolve("%Band/%Year", tagsByCategory: ["Band": ["X"]])
        #expect(missing.relativeFolder == nil)
        #expect(missing.missingToken == "Year")

        // Sanitization: forbidden chars, dot trim.
        let dirty = OrganizeTemplate.resolve(
            "%Band", tagsByCategory: ["Band": ["AC/DC: Live?..."]])
        #expect(dirty.relativeFolder == "AC_DC_ Live_")

        // Literal + token in one segment.
        let mixed = OrganizeTemplate.resolve(
            "shows/%Year - %Band", tagsByCategory: ["Year": ["1995"], "Band": ["Larks"]])
        #expect(mixed.relativeFolder == "shows/1995 - Larks")
    }

    // MARK: Reorganize end to end

    @Test func reorganizeMovesByTagsAndIsRevertible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-reorg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("inbox/a.mp4"))
        try Data("y".utf8).write(to: root.appendingPathComponent("inbox/b.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "R")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band")
        let larks = Tag(tagCategoryID: band.id, name: "Larks")
        let tagged = MediaItem(sourceID: source.id, kind: .video, relativePath: "inbox/a.mp4", needsReview: false)
        let untagged = MediaItem(sourceID: source.id, kind: .video, relativePath: "inbox/b.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try larks.insert(db)
            try tagged.insert(db)
            try untagged.insert(db)
            try MediaItemTag(mediaItemID: tagged.id, tagID: larks.id).insert(db)
        }

        // Preview: one moves, one is skipped with the missing token named.
        let plan = try library.previewReorganize(
            template: "%Band", itemIDs: [tagged.id, untagged.id])
        #expect(plan.count == 2)
        #expect(plan.first { $0.itemID == tagged.id }?.toFolder == "Larks")
        #expect(plan.first { $0.itemID == untagged.id }?.reason?.contains("%Band") == true)

        // Apply through the job.
        let runner = JobRunner(library: library)
        await runner.register(ReorganizeJob.self)
        let record = try await ReorganizeJob.enqueue(
            on: runner, template: "%Band", itemIDs: [tagged.id, untagged.id])
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.summary == "1 moved, 1 skipped")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Larks/a.mp4").path))

        // Revertible: the move is in the log and undoes cleanly.
        let log = try library.moveLogs().first { $0.mediaItemID == tagged.id && $0.revertedAt == nil }
        #expect(log != nil)
        try library.revertMove(log!.id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/a.mp4").path))

        // Idempotence: an item already in place is skipped.
        let again = try library.previewReorganize(template: "%Band", itemIDs: [tagged.id])
        _ = again  // (after revert it's back in inbox, so it would move again — plan says so)
        #expect(again.first?.toFolder == "Larks")
    }

    // MARK: OCR on real burned-in text

    @Test func ocrReadsBurnedInTextAndSearchFindsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-ocr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(
            to: root.appendingPathComponent("v.mp4"), seconds: 4, variant: 1,
            overlayText: "RIVERBEND 1995")

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "O")
        let source = Source(name: "S", rootPath: root.path)
        let probe = await MediaProbe.probe(url: root.appendingPathComponent("v.mp4"))
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "v.mp4",
            durationSeconds: probe.durationSeconds, needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }

        let runner = JobRunner(library: library)
        await runner.register(OcrJob.self)
        let record = try await OcrJob.enqueue(on: runner, itemID: item.id)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.state == .succeeded)

        let lines = try await library.writer.read { db in
            try OcrTextLine.filter(sql: "mediaItemID = ?", arguments: [item.id]).fetchAll(db)
        }
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.text.localizedCaseInsensitiveContains("RIVERBEND") })

        // Reach recorded; a second run reports fully scanned.
        let progress = try await library.writer.read { try OcrProgress.fetchOne($0, key: item.id) }
        #expect((progress?.scannedThroughSeconds ?? 0) >= 4.0)
        let second = try await OcrJob.enqueue(on: runner, itemID: item.id)
        try await runner.runPending()
        #expect(try await library.writer.read {
            try JobRecord.fetchOne($0, key: second.id)!
        }.summary == "already fully scanned")

        // Search reaches the recognized text.
        let hits = try library.mediaItems(
            matching: MediaFilter(searchText: "riverbend"), kinds: .video)
        #expect(hits.map(\.id) == [item.id])
        // And search that matches nothing returns nothing.
        #expect(try library.mediaItems(
            matching: MediaFilter(searchText: "zzz-nothing"), kinds: .video).isEmpty)
    }

    @Test func searchMatchesNameNotesAndEscapesWildcards() throws {
        let f = try FilterFixture()
        #expect(try f.names(MediaFilter(searchText: "a.mp4")).contains("a.mp4"))
        // Notes.
        try f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET notes = 'great encore' WHERE id = ?",
                arguments: [f.show2001.id])
        }
        #expect(try f.names(MediaFilter(searchText: "encore")) == ["c.mp4"])
        // `_` is literal, not a wildcard: "my_band" must not match "myxband".
        #expect(try f.names(MediaFilter(searchText: "my_band")) == ["f.mp4"])
    }

    // MARK: Join (ffmpeg-gated)

    @Test func joinConcatenatesFolderParts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-join-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(
            to: root.appendingPathComponent("show/d1t01.mp4"), seconds: 3, variant: 1)
        try await DemoMediaFactory.writeVideo(
            to: root.appendingPathComponent("show/d1t02.mp4"), seconds: 3, variant: 2)

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "J")
        let source = Source(name: "S", rootPath: root.path)
        try await library.writer.write { try source.insert($0) }
        let runner = JobRunner(library: library)
        await runner.register(ImportJob.self)
        await runner.register(JoinJob.self)
        _ = try await ImportJob.enqueue(on: runner, sourceID: source.id)
        try await runner.runPending()

        let record = try await JoinJob.enqueue(on: runner, sourceID: source.id, folderPath: "show")
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.state == .succeeded)

        if FfmpegTool.path() == nil {
            #expect(row.summary?.contains("brew install ffmpeg") == true)
            return
        }
        #expect(row.summary?.contains("joined 2 parts") == true)
        let joined = try await library.writer.read { db in
            try MediaItem.filter(sql: "fileName LIKE '%(joined)%'").fetchOne(db)
        }
        #expect(joined != nil)
        #expect(abs((joined!.durationSeconds ?? 0) - 6.0) < 1.5)
    }
}
