import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Save a Copy over an existing file must never lose that file: it used
/// to delete the destination first, so a copy that then failed (disk
/// full, source drive gone) left nothing at all.
@Suite struct SafeCopyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFailedCopyLeavesTheExistingFileAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("keep.mp4")
        try Data("old".utf8).write(to: destination)

        #expect(throws: (any Error).self) {
            try SafeCopy.copy(from: dir.appendingPathComponent("gone.mp4"), to: destination)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
    }

    @Test func aCopyReplacesTheExistingFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("new.mp4")
        let destination = dir.appendingPathComponent("keep.mp4")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)

        try SafeCopy.copy(from: source, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["keep.mp4", "new.mp4"])
    }
}
