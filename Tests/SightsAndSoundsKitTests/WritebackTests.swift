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

    /// The content hash is an MD5 of the whole file. A native tag write
    /// rewrites the tag block in place — the audio is untouched, but the
    /// bytes are not, so the stored hash no longer describes the file.
    /// Only the remux fallback used to clear it.
    @Test(.enabled(if: FfmpegTool.path() != nil && TagWriters.metaflacPath() != nil
        && TagWriters.ffprobePath() != nil))
    func aNativeTagWriteClearsTheStaleHashToo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-writeback-flac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("t.flac")
        try FfmpegTool.run(
            ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", file.path],
            tool: try #require(FfmpegTool.path()))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "W")
        let source = Source(name: "S", rootPath: root.path)
        let band = TagCategory(name: "Band", writebackField: "ARTIST")
        let larks = Tag(tagCategoryID: band.id, name: "Meadow Larks")
        let item = MediaItem(
            sourceID: source.id, kind: .audio, relativePath: "t.flac", fileSize: 1,
            contentHash: "stalehash", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try larks.insert(db)
            try item.insert(db)
            try MediaItemTag(mediaItemID: item.id, tagID: larks.id).insert(db)
            try MetadataSweepState(mediaItemID: item.id, failureMessage: nil).insert(db)
        }
        let runner = JobRunner(library: library)
        await runner.register(WritebackJob.self)
        _ = try await WritebackJob.enqueue(on: runner, itemIDs: [item.id], scopeDescription: "test")
        try await runner.runPending()

        let fileRow = try await library.writer.read { try TagWriteRunFile.fetchOne($0)! }
        #expect(fileRow.status == .written)
        #expect(!fileRow.usedRemuxFallback)  // metaflac did it
        let refreshed = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id)! }
        #expect(refreshed.contentHash == nil)
        // The tags it read are the ones just replaced: the next sweep
        // reads the file again.
        let swept = try await library.writer.read { try MetadataSweepState.fetchOne($0, key: item.id) }
        #expect(swept == nil, "the tags read before the write still count as swept")
        let onDisk = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
        #expect(refreshed.fileSize == onDisk)
    }

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
        // Which tool wrote it depends on the machine: AtomicParsley where
        // it is installed, the ffmpeg remux where it is not. Either is a
        // pass — this line used to insist on the remux, and failed on any
        // machine that had AtomicParsley.
        let refreshed = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id)! }
        if fileRow.usedRemuxFallback { #expect(refreshed.contentHash == nil) }

        // Restore the pre-write snapshot: the artist tag is gone again.
        let preWrite = snapshots.first { $0.source == .preWrite }!
        try await library.writer.write { try MetadataSweepState(mediaItemID: item.id, failureMessage: nil).upsert($0) }
        let restore = try await RestoreTagsJob.enqueue(on: runner, snapshotID: preWrite.id)
        try await runner.runPending()
        let restoreRow = try await library.writer.read { try JobRecord.fetchOne($0, key: restore.id)! }
        #expect(restoreRow.state == .succeeded)
        let sweptAfterRestore = try await library.writer.read { try MetadataSweepState.fetchOne($0, key: item.id) }
        #expect(sweptAfterRestore == nil, "the tags read before the restore still count as swept")

        let restored = try TagWriters.readTagsJSON(url: root.appendingPathComponent("t.m4a"))
        #expect(!restored.localizedCaseInsensitiveContains("Meadow Larks"))
        // And restoring left its own pre-restore snapshot.
        let allSnapshots = try await library.writer.read { db in
            try EmbeddedTagSnapshot.filter(sql: "mediaItemID = ?", arguments: [item.id]).fetchAll(db)
        }
        #expect(allSnapshots.contains { $0.source == .preRestore })
    }

    /// Restore into a file with tags from the snapshot's `tagsJSON`.
    private func restore(into name: String, make: [String], tagged: [String], snapshot tagsJSON: String)
        async throws -> (JobRecord, String)?
    {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(name)
        try FfmpegTool.run(make + tagged + [file.path], tool: ffmpeg)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Restore")
        let source = Source(name: "Here", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: name, needsReview: false)
        let snapshot = EmbeddedTagSnapshot(mediaItemID: item.id, source: .preWrite, tagsJSON: tagsJSON)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try snapshot.insert(db)
        }
        let runner = JobRunner(library: library)
        let restore = try await RestoreTagsJob.enqueue(on: runner, snapshotID: snapshot.id)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: restore.id)! }
        return (row, try TagWriters.readTagsJSON(url: file))
    }

    /// A restore aims at the snapshot's state. When the format can hold
    /// none of the snapshot's fields, a file with no tags is that state as
    /// near as the format allows, so the restore clears the file and says
    /// so. It was refused instead: a camera .mov whose snapshot held only
    /// its QuickTime make and model kept the title written over it, and
    /// the write could not be undone.
    @Test func aRestoreTheFormatCannotHoldStillClearsWhatWasWritten() async throws {
        guard let (row, after) = try await restore(
            into: "clip.mov",
            make: ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "libx264"],
            tagged: ["-metadata", "title=Written Title"],
            snapshot: #"{"format":{"tags":{"com.apple.quicktime.make":"Example","com.apple.quicktime.model":"Cam 1"}}}"#)
        else { return }
        #expect(row.state == .succeeded, "\(row.error ?? "")")
        #expect(!after.contains("Written Title"), "the written title was not cleared")
        #expect(row.summary?.contains("restored 0 of 2") == true, "\(row.summary ?? "")")
    }

    /// A .ts keeps no tags at all: restoring into one leaves it as it was
    /// (tagless) and says none of the fields could be held.
    @Test func aRestoreIntoAFileThatHoldsNoTagsSaysSo() async throws {
        guard let (row, _) = try await restore(
            into: "clip.ts",
            make: ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "mpeg2video"],
            tagged: [],
            snapshot: #"{"format":{"tags":{"artist":"The Examples","album":"Live Sets"}}}"#)
        else { return }
        #expect(row.state == .succeeded, "\(row.error ?? "")")
        #expect(row.summary?.contains("restored 0 of 2") == true, "\(row.summary ?? "")")
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
