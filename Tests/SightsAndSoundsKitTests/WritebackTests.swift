import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 8a: the ported field table and merge semantics (pure), and the
/// write→snapshot→restore loop against real files where the ffmpeg suite
/// exists.
@Suite struct WritebackTests {

    // MARK: StandardFields (ported table behavior)

    @Test func effectiveVorbisNameFoldsToAsciiUpper() {
        #expect(StandardFields.effectiveVorbisName(categoryName: "Band", writebackField: "ARTIST") == "ARTIST")
        #expect(StandardFields.effectiveVorbisName(categoryName: "Recording Type", writebackField: nil) == "RECORDING_TYPE")
        // Non-ASCII folds to '_' — unsafe as a Vorbis field name (ported).
        #expect(StandardFields.effectiveVorbisName(categoryName: "Café Décor", writebackField: nil) == "CAF__D_COR")
        // All-junk names fall back to TAG.
        #expect(StandardFields.effectiveVorbisName(categoryName: "%%%", writebackField: nil) == "TAG")
    }

    @Test func findIsCaseInsensitive() {
        #expect(StandardFields.find("artist")?.mp4Atom == "©ART")
        #expect(StandardFields.find("PERFORMER")?.mp4Freeform == true)
        #expect(StandardFields.find("NOPE") == nil)
        #expect(StandardFields.find(nil) == nil)
    }

    // MARK: WritebackMapping (ported merge semantics)

    @Test func resolveMapsMergesAndDedupes() {
        let mappings = [
            CategoryMapping(categoryName: "Band", enabled: true, writebackField: "ARTIST"),
            CategoryMapping(categoryName: "Guest", enabled: true, writebackField: "ARTIST"),
            CategoryMapping(categoryName: "Venue", enabled: true, writebackField: nil),
            CategoryMapping(categoryName: "Hidden", enabled: false, writebackField: "DATE"),
            CategoryMapping(categoryName: "Empty", enabled: true, writebackField: "GENRE"),
        ]
        let writes = WritebackMapping.resolve(
            mappings: mappings,
            tagsByCategory: [
                "Band": ["Larks", "Foxes"],
                "Guest": ["Foxes", "Extra"],  // 'Foxes' collides — dropped
                "Venue": ["Cedar Hall"],
                "Hidden": ["1999"],
            ])
        #expect(writes.count == 2)  // ARTIST (merged), VENUE; disabled + empty skipped

        let artist = writes.first { $0.vorbisName == "ARTIST" }
        #expect(artist?.values == ["Larks", "Foxes", "Extra"])  // order kept, dupe dropped
        #expect(artist?.mp4Atom == "©ART")

        let venue = writes.first { $0.vorbisName == "VENUE" }
        #expect(venue?.mp4Freeform == true)  // auto category → freeform
    }

    @Test func snapshotJSONFlattensToPairs() {
        let json = """
        {"format": {"tags": {"ARTIST": "Larks", "DATE": "1995"}},
         "streams": [{"tags": {"artist": "ShadowedByFormat", "ENCODER": "x"}}]}
        """
        let pairs = TagWriters.tagPairs(fromSnapshotJSON: json)
        // format tags win over stream tags of the same name (case-insensitive).
        #expect(pairs.first { $0.name.lowercased() == "artist" }?.value == "Larks")
        #expect(pairs.contains { $0.name == "ENCODER" })
        #expect(TagWriters.tagPairs(fromSnapshotJSON: "not json").isEmpty)
    }

    // MARK: End to end (ffmpeg-suite gated)

    @Test func writeSnapshotAndRestoreRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-writeback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoMediaFactory.writeAudio(to: root.appendingPathComponent("t.m4a"), seconds: 2)

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "W")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band", writebackField: "ARTIST")
        let larks = Tag(tagCategoryID: band.id, name: "Meadow Larks")
        let item = MediaItem(
            sourceID: source.id, kind: .audio, relativePath: "t.m4a",
            contentHash: "stalehash", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try larks.insert(db)
            try item.insert(db)
            try MediaItemTag(mediaItemID: item.id, tagID: larks.id).insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(WritebackJob.self)
        await runner.register(RestoreTagsJob.self)

        let record = try await WritebackJob.enqueue(
            on: runner, itemIDs: [item.id], scopeDescription: "test")
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        #expect(row.state == .succeeded)

        guard TagWriters.ffprobePath() != nil, FfmpegTool.path() != nil else {
            #expect(row.summary?.contains("brew install ffmpeg") == true)
            return
        }
        #expect(row.summary == "1 written, 0 skipped")

        // The file genuinely carries the tag now.
        let after = try TagWriters.readTagsJSON(url: root.appendingPathComponent("t.m4a"))
        #expect(after.localizedCaseInsensitiveContains("Meadow Larks"))

        // Paper trail: pre-write snapshot, run + file rows; stale hash
        // cleared by the fallback remux.
        let snapshots = try await library.writer.read { db in
            try EmbeddedTagSnapshot.filter(sql: "mediaItemID = ?", arguments: [item.id]).fetchAll(db)
        }
        #expect(snapshots.contains { $0.source == .preWrite })
        let runRow = try await library.writer.read { try TagWriteRun.fetchOne($0)! }
        #expect(runRow.writtenCount == 1 && runRow.finishedAt != nil)
        let fileRow = try await library.writer.read { try TagWriteRunFile.fetchOne($0)! }
        #expect(fileRow.status == .written)
        #expect(fileRow.usedRemuxFallback)  // no AtomicParsley for m4a audio? (it may exist — accept either)
        let refreshed = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id)! }
        if fileRow.usedRemuxFallback { #expect(refreshed.contentHash == nil) }

        // Restore the pre-write snapshot: the artist tag is gone again.
        let preWrite = snapshots.first { $0.source == .preWrite }!
        let restore = try await RestoreTagsJob.enqueue(on: runner, snapshotID: preWrite.id)
        try await runner.runPending()
        let restoreRow = try await library.writer.read { try JobRecord.fetchOne($0, key: restore.id)! }
        #expect(restoreRow.state == .succeeded)

        let restored = try TagWriters.readTagsJSON(url: root.appendingPathComponent("t.m4a"))
        #expect(!restored.localizedCaseInsensitiveContains("Meadow Larks"))
        // And restoring left its own pre-restore snapshot.
        let allSnapshots = try await library.writer.read { db in
            try EmbeddedTagSnapshot.filter(sql: "mediaItemID = ?", arguments: [item.id]).fetchAll(db)
        }
        #expect(allSnapshots.contains { $0.source == .preRestore })
    }

    @Test func itemsWithNoWritebackTagsAreSkippedHonestly() async throws {
        // A REAL file (so the offline check passes) whose categories have
        // write-back disabled — the skip must name the right reason.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-wbskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoMediaFactory.writeAudio(to: root.appendingPathComponent("t.m4a"), seconds: 2)

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "S")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band", writebackEnabled: false)
        let tag = Tag(tagCategoryID: band.id, name: "Larks")
        let item = MediaItem(sourceID: source.id, kind: .audio, relativePath: "t.m4a", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try tag.insert(db)
            try item.insert(db)
            try MediaItemTag(mediaItemID: item.id, tagID: tag.id).insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(WritebackJob.self)
        let record = try await WritebackJob.enqueue(
            on: runner, itemIDs: [item.id], scopeDescription: "test")
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: record.id)! }
        guard TagWriters.ffprobePath() != nil else { return }
        #expect(row.summary == "0 written, 1 skipped")
        let fileRow = try await library.writer.read { try TagWriteRunFile.fetchOne($0) }
        #expect(fileRow?.status == .skipped)
        #expect(fileRow?.error?.contains("no write-back-enabled tags") == true)
    }
}
