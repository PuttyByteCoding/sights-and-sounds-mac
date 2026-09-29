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
}
