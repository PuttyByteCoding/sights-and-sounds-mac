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

    /// With AtomicParsley, a restore wrote every tag it did not know as a
    /// custom iTunes atom — disc, copyright and grouping included — after
    /// `--metaEnema` had wiped the native ones. Music then showed none of
    /// them, and the next snapshot kept the custom spellings. A restored
    /// key with a native atom goes back to that atom.
    @Test func aRestoreWithAtomicParsleyPutsNativeKeysBackNatively() async throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil,
              let parsley = TagWriters.atomicParsleyPath()
        else { return }   // AtomicParsley is not on CI; this runs where it is installed
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-parsley-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("song.m4a")
        try FfmpegTool.run([
            "-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac",
            "-metadata", "disc=1/2", "-metadata", "copyright=Example Label",
            "-metadata", "grouping=Live Sets", "-metadata", "compilation=1", file.path,
        ], tool: ffmpeg)
        let snapshot = try TagWriters.readTagsJSON(url: file)

        let result = TagWriters.write(
            fields: SnapshotRestore.fields(fromSnapshotJSON: snapshot), to: file,
            tools: .init(metaflac: nil, atomicParsley: parsley, ffmpeg: ffmpeg))
        #expect(result.success, "\(result.error ?? "")")
        #expect(!result.usedRemuxFallback)

        let after = try TagWriters.readTagsJSON(url: file)
        // ffprobe reads native atoms under lower-case names and custom
        // iTunes atoms under the name they were given.
        for key in ["\"disc\"", "\"copyright\"", "\"grouping\"", "\"compilation\""] {
            #expect(after.contains(key), "\(key) is no longer a native atom: \(after)")
        }
        for key in ["\"DISC\"", "\"COPYRIGHT\"", "\"GROUPING\"", "\"COMPILATION\""] {
            #expect(!after.contains(key), "\(key) came back as a custom atom: \(after)")
        }
    }

    private func remux(_ name: String, make: [String], fields: [(String, String)]) throws -> (TagWriteResult, String)? {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-readback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(name)
        try FfmpegTool.run(make + [file.path], tool: ffmpeg)
        let result = TagWriters.ffmpegRemuxWrite(fields: fields.map { name, value in
            FieldWrite(vorbisName: name, mp4Atom: name, mp4Freeform: true, values: [value])
        }, url: file)
        return (result, try TagWriters.readTagsJSON(url: file))
    }

    /// A .mov keeps a location of any text (©xyz). The measured key set
    /// left it out, so a .mov's location — phone cameras write one — was
    /// named not written and not put back by a restore.
    @Test func aMovKeepsItsLocation() throws {
        guard let (result, after) = try remux("clip.mov",
            make: ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "libx264"],
            fields: [("LOCATION", "Paris, France")]) else { return }
        #expect(result.success, "\(result.error ?? "")")
        #expect(after.contains("Paris, France"))
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
    }

    /// Every remux reads its tags back, and a field that did not come back
    /// is named — for every container, not only MP4. A .wav keeps title,
    /// artist, genre and track, but has no place for album artist, which
    /// vanished under a success.
    @Test func aWavNamesWhatItsMuxerDropped() throws {
        guard let (result, after) = try remux("song.wav",
            make: ["-f", "lavfi", "-i", "sine=duration=1"],
            fields: [("TITLE", "Night One"), ("ALBUMARTIST", "The Examples"), ("TRACKNUMBER", "7")]) else { return }
        #expect(result.success, "\(result.error ?? "")")
        #expect(after.contains("Night One"))
        // Track lands too, written under ffmpeg's generic name; album
        // artist has no place in a WAV.
        #expect(result.notWritten == ["ALBUMARTIST"], "\(result.notWritten)")
    }

    /// An .m4a keeps a location only in ISO 6709 form; plain text is
    /// dropped by the muxer, and the read-back names it.
    @Test func anM4ANamesALocationItCouldNotHold() throws {
        guard let (result, after) = try remux("song.m4a",
            make: ["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac"],
            fields: [("LOCATION", "+40.7-074/"), ("TITLE", "Night One")]) else { return }
        // Stored, and read back reformatted (+40.7000-074.0000/): kept.
        #expect(after.contains("+40.7"))
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
        guard let (plain, _) = try remux("song.m4a",
            make: ["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac"],
            fields: [("LOCATION", "Paris, France")]) else { return }
        #expect(plain.notWritten == ["LOCATION"], "\(plain.notWritten)")
    }

    /// Outside MP4 the fields went in under their Vorbis names, so an MP3
    /// got TXXX:TRACKNUMBER and TXXX:ALBUMARTIST — custom frames players do
    /// not show — and the read-back found them by name and said written.
    /// They go in under ffmpeg's generic names now, which land in TRCK and
    /// TPE2 (and as TRACKNUMBER/ALBUMARTIST in Ogg and FLAC).
    @Test func anMP3GetsItsTrackAndAlbumArtistInTheirOwnFrames() throws {
        guard let ffmpeg = FfmpegTool.path(), TagWriters.ffprobePath() != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remux-mp3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("song.mp3")
        try FfmpegTool.run(["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "libmp3lame", file.path], tool: ffmpeg)

        let result = TagWriters.ffmpegRemuxWrite(fields: [
            FieldWrite(vorbisName: "TRACKNUMBER", mp4Atom: "trkn", mp4Freeform: false, values: ["3/9"]),
            FieldWrite(vorbisName: "ALBUMARTIST", mp4Atom: "aART", mp4Freeform: false, values: ["The Examples"]),
        ], url: file)
        #expect(result.success, "\(result.error ?? "")")
        let bytes = try Data(contentsOf: file)
        for frame in ["TRCK", "TPE2"] {
            #expect(bytes.range(of: Data(frame.utf8)) != nil, "no \(frame) frame")
        }
        #expect(bytes.range(of: Data("TRACKNUMBER".utf8)) == nil, "written as a custom frame")
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
    }

    /// A container reformats values on read (track 07 comes back 7). The
    /// read-back compared values and named such fields "not written"; it
    /// asks whether the tag is there now.
    @Test func aValueReformattedOnReadIsStillWritten() throws {
        guard let (result, _) = try remux("song.m4a",
            make: ["-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac"],
            fields: [("TRACKNUMBER", "07"), ("DISC", "01/02")]) else { return }
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
    }

    /// AVI keeps an album as IPRD, which reads back as "product".
    @Test func anAviAlbumIsKept() throws {
        guard let (result, _) = try remux("clip.avi",
            make: ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "mpeg4"],
            fields: [("ALBUM", "Live Sets"), ("TITLE", "Night One")]) else { return }
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
    }

    /// The note blamed a missing AtomicParsley on every container and
    /// listed every name; it says the format did not keep them, names at
    /// most ten, and mentions AtomicParsley only where it would help.
    @Test func theNoteSaysWhatTheFormatDidNotKeepBriefly() {
        let names = (1...12).map { "FIELD\($0)" }
        let note = TagWriteResult(success: true, usedRemuxFallback: true, error: nil, notWritten: names).writtenNote ?? ""
        #expect(note.contains("not kept by this file's format"), "\(note)")
        #expect(note.contains("FIELD10") && !note.contains("FIELD11"), "\(note)")
        #expect(note.contains("and 2 more"), "\(note)")
        #expect(!note.contains("AtomicParsley"), "\(note)")
        let mp4 = TagWriteResult(success: true, usedRemuxFallback: true, error: nil, notWritten: ["PERFORMER"],
                                 atomicParsleyWouldHelp: true).writtenNote ?? ""
        #expect(mp4.contains("AtomicParsley"), "\(mp4)")
    }

    /// A write that kept none of its fields left the file's old tags wiped
    /// and nothing in their place, and was counted "written".
    @Test func aWriteThatKeptNothingIsRecognised() {
        let none = TagWriteResult(success: true, usedRemuxFallback: true, error: nil, notWritten: ["A", "B"])
        #expect(none.keptNothing(of: 2))
        #expect(!none.keptNothing(of: 3))
    }

    /// ffmpeg writes a DESCRIPTION comment into Vorbis files but reads it
    /// back as "comment"; it was named not kept, and a write of that field
    /// alone counted as failed.
    @Test func aVorbisDescriptionIsKept() throws {
        guard let (result, _) = try remux("song.flac",
            make: ["-f", "lavfi", "-i", "sine=duration=1"],
            fields: [("DESCRIPTION", "A night recording")]) else { return }
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
    }

    /// AIFF keeps only a name and an annotation of its own; the rest go in
    /// an ID3 chunk (where Music keeps AIFF tags), which the remux did not
    /// write and so stripped.
    @Test func anAiffKeepsItsTagsInAnID3Chunk() throws {
        guard let (result, after) = try remux("song.aiff",
            make: ["-f", "lavfi", "-i", "sine=duration=1"],
            fields: [("ARTIST", "The Examples"), ("ALBUM", "Live Sets"), ("GENRE", "Folk")]) else { return }
        #expect(result.notWritten.isEmpty, "\(result.notWritten)")
        #expect(after.contains("The Examples"))
    }

    /// The ffmpeg tool sets its own encoder tag over any given, so a
    /// field named ENCODER was replaced — yet present, so counted kept.
    @Test func anEncoderFieldIsNamedNotKept() throws {
        guard let (result, _) = try remux("song.wav",
            make: ["-f", "lavfi", "-i", "sine=duration=1"],
            fields: [("ENCODER", "My Rig"), ("TITLE", "Night One")]) else { return }
        #expect(result.notWritten == ["ENCODER"], "\(result.notWritten)")
    }
}
