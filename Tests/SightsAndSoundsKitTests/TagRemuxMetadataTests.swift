import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The ffmpeg remux is the write-back for every container without a
/// native tag tool, and the fallback for MP4 when AtomicParsley is
/// missing or fails. It is a wipe-and-rewrite of the FILE's tags — but
/// `-map_metadata -1` wiped every stream's too (track languages, titles,
/// handler names), which the snapshot cannot restore; and ffmpeg's MP4
/// muxer drops keys it does not know, so custom fields (PERFORMER, a
/// category's own field) silently never landed under a success. They
/// are now named as not written.
@Suite struct TagRemuxMetadataTests {
    @Test func theRemuxKeepsStreamLanguagesAndWritesCustomFields() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain.mp4")
        let file = root.appendingPathComponent("show.mp4")
        try await DemoMediaFactory.writeVideo(to: plain, seconds: 1)
        try FfmpegTool.run([
            "-i", plain.path, "-map", "0", "-c", "copy",
            "-metadata:s:v:0", "language=fra",
            "-metadata", "comment=an old file tag",
            file.path,
        ], tool: ffmpeg)
        #expect(try TagWriters.readTagsJSON(url: file).contains("fra"))

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "TITLE", mp4Atom: "©nam", mp4Freeform: false, values: ["Night One"]),
            FieldWrite(vorbisName: "PERFORMER", mp4Atom: "PERFORMER", mp4Freeform: true, values: ["The Examples"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")

        let after = try TagWriters.readTagsJSON(url: file)
        #expect(after.contains("Night One"))
        #expect(result.notWritten == ["PERFORMER"], "a custom field the MP4 muxer drops must be named")
        #expect(result.writtenNote?.contains("PERFORMER") == true)
        #expect(after.contains("\"fra\""), "the stream's language was wiped")
        #expect(!after.contains("an old file tag"), "the file's old tags must still be replaced")
    }

    /// ffmpeg's MP4 muxer knows album artist and track number only as
    /// `album_artist` and `track`. Given the Vorbis names, it dropped both
    /// — standard fields, not custom ones — and nothing said so. Every
    /// standard field now lands.
    @Test func everyStandardFieldReachesAnMP4() async throws {
        guard FfmpegTool.path() != nil, TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-mp4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("show.mp4")
        try await DemoMediaFactory.writeVideo(to: file, seconds: 1)
        let standard = StandardFields.all.filter { !$0.mp4Freeform }
        var fields: [FieldWrite] = []
        for (index, field) in standard.enumerated() {
            let value: String
            switch field.vorbisName {
            case "TRACKNUMBER": value = "7"
            case "DATE": value = "1999"
            default: value = "Value\(index)"
            }
            fields.append(FieldWrite(
                vorbisName: field.vorbisName, mp4Atom: field.mp4Atom, mp4Freeform: false, values: [value]))
        }

        let result = TagWriters.ffmpegRemuxWrite(fields: fields, url: file)
        #expect(result.success, "\(result.error ?? "")")
        #expect(result.notWritten.isEmpty)

        let after = try TagWriters.readTagsJSON(url: file)
        for field in fields {
            let quoted = "\"" + field.values[0]
            #expect(after.contains(quoted), "\(field.vorbisName) did not land: \(after)")
        }
    }

    /// Ogg keeps its Vorbis comments on the stream, not the file. Clearing
    /// only the file's tags (above) left the old comments in place, and a
    /// file-level `-metadata` is not written by the Ogg muxer at all: a
    /// write-back to .ogg or .opus said "written" and changed nothing.
    @Test(arguments: [("ogg", ["-c:a", "flac"]), ("opus", ["-c:a", "libopus", "-b:a", "64k"])])
    func anOggFilesCommentsAreReplaced(_ ext: String, _ codec: [String]) throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-ogg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("song.\(ext)")
        try FfmpegTool.run([
            "-f", "lavfi", "-i", "sine=f=440:duration=1:sample_rate=48000",
            "-metadata:s:a:0", "TITLE=Old", "-metadata:s:a:0", "ARTIST=Old Artist",
        ] + codec + [file.path], tool: ffmpeg)
        #expect(try TagWriters.readTagsJSON(url: file).contains("Old Artist"))

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "TITLE", mp4Atom: "©nam", mp4Freeform: false, values: ["New"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")

        let after = try TagWriters.readTagsJSON(url: file)
        #expect(after.contains("\"New\""), "the new title was not written: \(after)")
        #expect(!after.contains("Old Artist"), "the old comments were kept: \(after)")
    }

    /// A snapshot restore marks every tag it does not know as custom — but
    /// the MOV muxer writes many of them (disc, copyright, grouping…). The
    /// remux wiped them from the file and named them "not written", so a
    /// restore without AtomicParsley lost what the snapshot held. Only a
    /// key the muxer really drops is named now.
    @Test func aRestoreIntoAnM4AKeepsEveryKeyTheMuxerWrites() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-m4a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("song.m4a")
        try FfmpegTool.run(["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac", file.path], tool: ffmpeg)

        let snapshot = #"{"format":{"tags":{"disc":"1/2","copyright":"Example Label","grouping":"Live Sets","foo":"bar"}}}"#
        let fields = SnapshotRestore.fields(fromSnapshotJSON: snapshot)
        let result = TagWriters.ffmpegRemuxWrite(fields: fields, url: file)
        #expect(result.success, "\(result.error ?? "")")

        let after = try TagWriters.readTagsJSON(url: file)
        for value in ["1/2", "Example Label", "Live Sets"] {
            #expect(after.contains(value), "\(value) was dropped: \(after)")
        }
        #expect(result.notWritten == ["FOO"], "\(result.notWritten)")
    }

    /// Ogg keeps its tags on a stream, and the remux wrote them onto the
    /// first audio stream. A video-only .ogv has none: ffmpeg exited 0,
    /// the old tags were cleared and the new ones went nowhere — a
    /// success that lost every tag.
    @Test func aVideoOnlyOggKeepsTheTagsItIsGiven() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-ogv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.ogv")
        try FfmpegTool.run([
            "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "libvpx", file.path,
        ], tool: ffmpeg)

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "TITLE", mp4Atom: "©nam", mp4Freeform: false, values: ["Night One"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")
        #expect(try TagWriters.readTagsJSON(url: file).contains("Night One"), "the title went nowhere")
    }

    /// A .mov is written by the same muxer in QuickTime mode, which keeps
    /// only seven keys. Album artist, grouping and the rest vanished from
    /// a .mov under a success (AtomicParsley refuses .mov, so the remux is
    /// its only writer). They are named as not written now.
    @Test func aMovNamesTheKeysItsMuxerDrops() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-mov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.mov")
        try FfmpegTool.run([
            "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "libx264", file.path,
        ], tool: ffmpeg)

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "TITLE", mp4Atom: "©nam", mp4Freeform: false, values: ["Night One"]),
            FieldWrite(vorbisName: "ALBUMARTIST", mp4Atom: "aART", mp4Freeform: false, values: ["The Examples"]),
            FieldWrite(vorbisName: "GROUPING", mp4Atom: "GROUPING", mp4Freeform: true, values: ["Live Sets"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")
        #expect(try TagWriters.readTagsJSON(url: file).contains("Night One"))
        #expect(Set(result.notWritten) == ["ALBUMARTIST", "GROUPING"], "\(result.notWritten)")
    }

    /// Some MP4 keys are numbers. Given text, the muxer stored 0 (a
    /// category "Compilation: Summer Hits" set the compilation flag off)
    /// or dropped it, and the write still read as a success. A value the
    /// key cannot hold is named as not written.
    @Test func aNumberKeyGivenTextIsNamedNotCoerced() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("song.m4a")
        try FfmpegTool.run(["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac", file.path], tool: ffmpeg)

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "COMPILATION", mp4Atom: "COMPILATION", mp4Freeform: true, values: ["Summer Hits"]),
            FieldWrite(vorbisName: "TRACK", mp4Atom: "TRACK", mp4Freeform: true, values: ["abc"]),
            FieldWrite(vorbisName: "DISC", mp4Atom: "DISC", mp4Freeform: true, values: ["1/2"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")
        #expect(try TagWriters.readTagsJSON(url: file).contains("1/2"), "a valid disc number was dropped")
        #expect(Set(result.notWritten) == ["COMPILATION", "TRACK"], "\(result.notWritten)")
    }
}
