import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The native-tool rung of the write ladder, driven with stand-in tools
/// so it runs on any machine: what the tool is asked to do, and what
/// happens to its error when it fails.
@Suite struct TagWritersTests {

    /// A stand-in tool: appends one line per invocation (its arguments)
    /// to `log`, prints `stderr`, exits with `status`.
    private struct Stub {
        let dir: URL
        let tool: URL
        let log: URL

        init(status: Int32 = 0, stderr: String = "") throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-tagtool-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tool = dir.appendingPathComponent("tool")
            log = dir.appendingPathComponent("calls.log")
            let script = """
                #!/bin/sh
                echo "$@" >> '\(log.path)'
                echo '\(stderr)' >&2
                exit \(status)

                """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        var calls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func tearDown() { try? FileManager.default.removeItem(at: dir) }
    }

    private let fields = [
        FieldWrite(vorbisName: "ARTIST", mp4Atom: "©ART", mp4Freeform: false, values: ["Band A"]),
        FieldWrite(vorbisName: "VENUE", mp4Atom: "VENUE", mp4Freeform: true, values: ["Hall", "Club"]),
    ]

    @Test func aFlacWriteIsOneMetaflacInvocation() throws {
        let stub = try Stub()
        defer { stub.tearDown() }
        let file = stub.dir.appendingPathComponent("song.flac")

        let result = TagWriters.write(
            fields: fields, to: file,
            tools: .init(metaflac: stub.tool.path, atomicParsley: nil, ffmpeg: nil))

        #expect(result.success)
        #expect(!result.usedRemuxFallback)
        // Wipe and rewrite in a single pass: a separate wipe leaves the
        // file with no tags at all if the rewrite then fails.
        #expect(stub.calls == [
            "--remove-all-tags --set-tag=ARTIST=Band A --set-tag=VENUE=Hall --set-tag=VENUE=Club \(file.path)",
        ])
    }

    @Test func aFailedNativeToolIsReportedNotSwallowed() throws {
        let stub = try Stub(status: 3, stderr: "field name is invalid")
        defer { stub.tearDown() }
        let file = stub.dir.appendingPathComponent("song.flac")

        let result = TagWriters.write(
            fields: fields, to: file,
            tools: .init(metaflac: stub.tool.path, atomicParsley: nil, ffmpeg: nil))

        // No ffmpeg to fall back on: the write failed, and the reason the
        // native tool gave is part of the answer.
        #expect(!result.success)
        #expect(result.nativeToolError?.contains("field name is invalid") == true)
        #expect(result.error?.contains("field name is invalid") == true)
        #expect(stub.calls.count == 1)  // and the file was never wiped on its own
    }

    @Test func aLongToolErrorKeepsItsFirstLines() {
        // metaflac prints the actual error, then pages of usage text.
        let output = "ERROR: field name contains invalid character\n"
            + String(repeating: "usage text ", count: 100)
        let excerpt = TagWriters.excerpt(of: output)
        #expect(excerpt.hasPrefix("ERROR: field name contains invalid character"))
        #expect(excerpt.count < 420)
        #expect(TagWriters.excerpt(of: " short \n") == "short")
    }
}
