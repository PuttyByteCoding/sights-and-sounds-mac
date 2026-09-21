import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// A move changes the disk and then the database, and those cannot be one
/// transaction. If the app dies between them the file is at the new path,
/// the row at the old one, and nothing records that a move was under way:
/// the item reads as missing, the next scan imports the file as a new
/// untagged item, and the row that holds the curated tags is the one
/// offered for deletion. The journal is what makes that recoverable.
@Suite struct MoveJournalTests {

    private struct Fixture {
        let library: LibraryDatabase
        let source: Source
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-journal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Journal")
            source = Source(name: "S", rootPath: root.path)
            try library.writer.write { [source] in try source.insert($0) }
        }

        func addItem(_ path: String) throws -> MediaItem {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("media".utf8).write(to: url)
            let item = MediaItem(sourceID: source.id, kind: .video, relativePath: path)
            try library.writer.write { try item.insert($0) }
            return item
        }

        func moveOnDisk(_ from: String, _ to: String) throws {
            let destination = root.appendingPathComponent(to)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: destination)
        }

        func path(of item: MediaItem) throws -> String {
            try library.writer.read { try MediaItem.fetchOne($0, key: item.id)!.relativePath }
        }

        var pending: Int {
            get throws { try library.writer.read { try PendingMove.fetchCount($0) } }
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private struct RefusingMoves: FileAccess {
        let live = LiveFileAccess()
        struct Refused: Error {}
        func isReachable(_ url: URL) -> Bool { live.isReachable(url) }
        func contentsOfDirectory(at url: URL) throws -> [URL] { try live.contentsOfDirectory(at: url) }
        func allFiles(under url: URL) throws -> [URL] { try live.allFiles(under: url) }
        func fileSize(at url: URL) throws -> Int64 { try live.fileSize(at: url) }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws { try live.readFile(at: url, chunk: chunk) }
        func removeFile(at url: URL) throws { try live.removeFile(at: url) }
        func moveFile(at url: URL, to destination: URL) throws { throw Refused() }
    }

    @Test func anOrdinaryMoveLeavesNothingPending() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let item = try f.addItem("inbox/a.mp4")

        try f.library.moveFile(itemID: item.id, to: "shows/a.mp4")

        #expect(try f.pending == 0)
        #expect(try f.library.moveLogs().count == 1)
    }

    @Test func aMoveTheDiskRefusedLeavesNothingPending() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let item = try f.addItem("inbox/a.mp4")

        #expect(throws: (any Error).self) {
            try f.library.moveFile(itemID: item.id, to: "shows/a.mp4", fileAccess: RefusingMoves())
        }

        #expect(try f.pending == 0)
        #expect(try f.path(of: item) == "inbox/a.mp4")
        #expect(try f.library.moveLogs().isEmpty)
    }

    /// The app died after the file moved and before the row followed.
    @Test func aMoveThatReachedTheDiskIsFinishedOnTheNextOpen() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let item = try f.addItem("inbox/a.mp4")
        let session = UUID()
        try f.library.writer.write { [source = f.source] db in
            try PendingMove(
                mediaItemID: item.id, sourceID: source.id, fileName: "a.mp4",
                fromPath: "inbox/a.mp4", toPath: "shows/a.mp4", sessionID: session).insert(db)
        }
        try f.moveOnDisk("inbox/a.mp4", "shows/a.mp4")

        let outcome = try f.library.reconcileInterruptedMoves()

        #expect(outcome.finished == 1)
        #expect(try f.path(of: item) == "shows/a.mp4")
        #expect(try f.pending == 0)
        // …and it is an ordinary, revertible move in the history.
        let log = try #require(try f.library.moveLogs().first)
        #expect(log.fromPath == "inbox/a.mp4" && log.toPath == "shows/a.mp4")
        #expect(log.sessionID == session)
        try f.library.revertMove(log.id)
        #expect(try f.path(of: item) == "inbox/a.mp4")
    }

    /// The app died after writing down the intent and before the disk moved.
    @Test func aMoveThatNeverReachedTheDiskIsForgotten() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let item = try f.addItem("inbox/a.mp4")
        try f.library.writer.write { [source = f.source] db in
            try PendingMove(
                mediaItemID: item.id, sourceID: source.id, fileName: "a.mp4",
                fromPath: "inbox/a.mp4", toPath: "shows/a.mp4", sessionID: nil).insert(db)
        }

        let outcome = try f.library.reconcileInterruptedMoves()

        #expect(outcome.forgotten == 1)
        #expect(try f.path(of: item) == "inbox/a.mp4")
        #expect(try f.pending == 0)
        #expect(try f.library.moveLogs().isEmpty)
    }

    /// Neither place, or both: not something to guess at. It stays
    /// pending and is reported, so a drive that was simply unplugged
    /// gets its answer when it comes back.
    @Test func whatCannotBeDecidedIsLeftPendingAndReported() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let item = try f.addItem("inbox/a.mp4")
        try f.library.writer.write { [source = f.source] db in
            try PendingMove(
                mediaItemID: item.id, sourceID: source.id, fileName: "a.mp4",
                fromPath: "inbox/a.mp4", toPath: "shows/a.mp4", sessionID: nil).insert(db)
        }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("inbox/a.mp4"))

        let outcome = try f.library.reconcileInterruptedMoves()

        #expect(outcome.undecided == 1)
        #expect(try f.pending == 1)
        #expect(try f.path(of: item) == "inbox/a.mp4")
    }
}
