import Foundation
import Testing
@testable import SightsAndSoundsKit

/// A tag write replaces a file's text tags with the library's. Cover art
/// is not a text tag and the library does not hold it, so a write that
/// loses it has destroyed something that cannot be put back from the
/// snapshot either (snapshots record text tags). AtomicParsley's
/// `--metaEnema` — "remove all metadata" — takes the art with it.
@Suite struct CoverArtTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-cover-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let fields = [
        FieldWrite(vorbisName: "ARTIST", mp4Atom: "©ART", mp4Freeform: false, values: ["Band A"]),
    ]

    /// Runs anywhere: a stand-in AtomicParsley that "extracts" two images
    /// when asked, and records what it was told to do.
    @Test func theArtInTheFileIsHandedBackInTheSameWrite() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("AtomicParsley")
        let log = dir.appendingPathComponent("calls.log")
        let script = """
            #!/bin/bash
            echo "$@" >> '\(log.path)'
            if [ "$2" = "--extractPixToPath" ]; then
              printf 'one' > "$3_artwork_1.png"
              printf 'two' > "$3_artwork_2.jpg"
            fi
            exit 0

            """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let file = dir.appendingPathComponent("song.m4a")

        let result = TagWriters.write(
            fields: fields, to: file,
            tools: .init(metaflac: nil, atomicParsley: tool.path, ffmpeg: nil))

        #expect(result.success && !result.usedRemuxFallback)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.count == 2)
        #expect(calls.first?.contains("--extractPixToPath") == true)
        // The wipe and the art go in one invocation, art in its order.
        let write = try #require(calls.last)
        #expect(write.contains("--metaEnema"))
        let first = try #require(write.range(of: "_artwork_1.png"))
        let second = try #require(write.range(of: "_artwork_2.jpg"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(write.components(separatedBy: "--artwork ").count == 3)
    }

    /// The real thing, where the tools are installed.
    @Test(.enabled(if: TagWriters.atomicParsleyPath() != nil && FfmpegTool.path() != nil
        && TagWriters.ffprobePath() != nil))
    func aRealWriteLeavesTheCoverWhereItWas() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = try #require(FfmpegTool.path())
        let cover = dir.appendingPathComponent("cover.png")
        let plain = dir.appendingPathComponent("plain.m4a")
        let file = dir.appendingPathComponent("song.m4a")
        try FfmpegTool.run(["-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", cover.path], tool: ffmpeg)
        try FfmpegTool.run(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", plain.path], tool: ffmpeg)
        try FfmpegTool.run(
            ["-i", plain.path, "-i", cover.path, "-map", "0", "-map", "1", "-c", "copy",
             "-disposition:v:0", "attached_pic", "-metadata", "ARTIST=Old", file.path],
            tool: ffmpeg)
        #expect(try Self.hasAttachedPicture(file))

        let result = TagWriters.write(
            fields: fields, to: file,
            tools: .init(metaflac: nil, atomicParsley: TagWriters.atomicParsleyPath(), ffmpeg: nil))

        #expect(result.success && !result.usedRemuxFallback)
        #expect(try Self.hasAttachedPicture(file))
        #expect(try TagWriters.readTagsJSON(url: file).contains("Band A"))
        #expect(try !TagWriters.readTagsJSON(url: file).contains("Old"))
    }

    private static func hasAttachedPicture(_ file: URL) throws -> Bool {
        let ffprobe = try #require(TagWriters.ffprobePath())
        let output = try ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "stream_disposition=attached_pic", "-of", "csv=p=0", file.path,
        ])
        return output.stdoutText.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "1" }
    }
}
