import Foundation
import Testing

@testable import SightsAndSoundsKit

/// On a case-insensitive volume (APFS's default) a path that differs
/// only in case IS the file being moved. Treating it as a collision
/// stamped the name: `rock/x.mp4` → `Rock/x-20260928….mp4`.
@Suite struct CaseOnlyMoveTests {
    @Test func aCaseOnlyMoveKeepsTheFileName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("rock/x.mp4")
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: original)
        // Only meaningful where the volume ignores case.
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        try #require(!caseSensitive)

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "CaseOnly")
        let source = Source(name: "Here", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "rock/x.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }

        let log = try library.moveFile(itemID: item.id, to: "Rock/x.mp4")

        #expect(log.toPath == "Rock/x.mp4")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rock/x.mp4").path))
        let moved = try await library.writer.read { try MediaItem.fetchOne($0, key: item.id) }
        #expect(moved?.relativePath == "Rock/x.mp4")
    }
}
