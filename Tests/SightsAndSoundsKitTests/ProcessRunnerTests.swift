import Foundation
import Testing
@testable import SightsAndSoundsKit

/// A child process that writes more than a pipe holds (about 64 KB)
/// blocks until someone reads. Every tool call used to wait for exit
/// first and read afterwards, so a talkative tool and the app waited on
/// each other forever — and the job lane with them. Each test here hangs
/// on that code, which is why each carries a time limit.
@Suite struct ProcessRunnerTests {

    /// A stand-in tool that floods both streams, then exits with `status`.
    private func chattyTool(status: Int32 = 0, stdoutPrefix: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-chatty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("tool")
        let script = """
            #!/bin/sh
            printf '%s' '\(stdoutPrefix)'
            i=0
            while [ $i -lt 4000 ]; do
              echo "stdout line $i: 0123456789012345678901234567890123456789012345678901234567890123456789"
              echo "stderr line $i: 0123456789012345678901234567890123456789012345678901234567890123456789" >&2
              i=$((i+1))
            done
            exit \(status)

            """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func remove(_ tool: URL) {
        try? FileManager.default.removeItem(at: tool.deletingLastPathComponent())
    }

    @Test(.timeLimit(.minutes(1)))
    func bothStreamsAreReadWhileTheToolRuns() throws {
        let tool = try chattyTool()
        defer { remove(tool) }

        let output = try ProcessRunner.run(tool.path, [])

        #expect(output.status == 0)
        #expect(output.stdout.count > 300_000)
        #expect(output.stderr.count > 300_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTalkativeFfmpegDoesNotHangTheLane() throws {
        let tool = try chattyTool()
        defer { remove(tool) }
        try FfmpegTool.run(["-i", "in.mp4", "out.mp4"], tool: tool.path)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailingTalkativeFfmpegStillReportsItsError() throws {
        let tool = try chattyTool(status: 2)
        defer { remove(tool) }
        #expect(throws: FfmpegTool.FfmpegError.self) {
            try FfmpegTool.run([], tool: tool.path)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aTalkativeTagToolDoesNotHangTheWrite() throws {
        let tool = try chattyTool()
        defer { remove(tool) }
        let result = TagWriters.write(
            fields: [FieldWrite(vorbisName: "ARTIST", mp4Atom: "©ART", mp4Freeform: false, values: ["A"])],
            to: URL(fileURLWithPath: "/tmp/sas-chatty.flac"),
            tools: .init(metaflac: tool.path, atomicParsley: nil, ffmpeg: nil))
        #expect(result.success)
    }
}
