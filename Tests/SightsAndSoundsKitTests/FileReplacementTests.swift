import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Remux and Repair swap an item's file for a new one: archive the
/// original, move the result into place. Between those two moves the
/// item has no file, so everything that can fail is checked before the
/// first, and a failure of the second puts the original back.
@Suite struct FileReplacementTests {

    /// Real files in a temp root; `failMovesTo` makes any move whose
    /// destination ends with that suffix throw, like a full disk would.
    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-replace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        func read(_ relative: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(relative)))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private struct FailingMoves: FileAccess {
        let live = LiveFileAccess()
        let failMovesTo: String
        struct DiskFull: Error {}

        func isReachable(_ url: URL) -> Bool { live.isReachable(url) }
        func contentsOfDirectory(at url: URL) throws -> [URL] { try live.contentsOfDirectory(at: url) }
        func allFiles(under url: URL) throws -> [URL] { try live.allFiles(under: url) }
        func fileSize(at url: URL) throws -> Int64 { try live.fileSize(at: url) }
        func readFile(at url: URL, chunk: (Data) throws -> Void) throws { try live.readFile(at: url, chunk: chunk) }
        func removeFile(at url: URL) throws { try live.removeFile(at: url) }
        func moveFile(at url: URL, to destination: URL) throws {
            // The archive keeps the same tail under _Replaced/; only the
            // item's own location is the one that is "full".
            if destination.path.hasSuffix(failMovesTo),
               !destination.path.contains("/\(MediaPath.archiveFolder)/") { throw DiskFull() }
            try live.moveFile(at: url, to: destination)
        }
    }

    @Test func theOriginalIsArchivedAndTheResultTakesItsPlace() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try f.write("shows/a.mkv", "original")
        let result = try f.write("work/result.mp4", "remuxed")

        let archive = try LibraryDatabase.replaceFile(
            under: f.root, currentRelative: "shows/a.mkv", newRelative: "shows/a.mp4",
            with: result, fileAccess: LiveFileAccess())

        #expect(archive == "_Replaced/shows/a.mkv")
        #expect(f.read("_Replaced/shows/a.mkv") == "original")
        #expect(f.read("shows/a.mp4") == "remuxed")
        #expect(f.read("shows/a.mkv") == nil)
    }

    @Test func aNameAlreadyTakenIsRefusedBeforeAnythingMoves() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try f.write("shows/a.mkv", "original")
        _ = try f.write("shows/a.mp4", "someone else")
        let result = try f.write("work/result.mp4", "remuxed")

        #expect(throws: FileReplacementError.self) {
            try LibraryDatabase.replaceFile(
                under: f.root, currentRelative: "shows/a.mkv", newRelative: "shows/a.mp4",
                with: result, fileAccess: LiveFileAccess())
        }
        // The item still has its file, and nobody else's was touched.
        #expect(f.read("shows/a.mkv") == "original")
        #expect(f.read("shows/a.mp4") == "someone else")
        #expect(f.read("_Replaced/shows/a.mkv") == nil)
    }

    @Test func whenEvenPuttingItBackFailsTheErrorSaysWhereTheOriginalIs() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try f.write("shows/a.mp4", "original")
        let result = try f.write("work/result.mp4", "repaired")

        // Same name in and out, so the refused landing refuses the way
        // back too: the worst case, and it must not be a silent one.
        do {
            try LibraryDatabase.replaceFile(
                under: f.root, currentRelative: "shows/a.mp4", newRelative: "shows/a.mp4",
                with: result, fileAccess: FailingMoves(failMovesTo: "/shows/a.mp4"))
            Issue.record("the replacement should have failed")
        } catch FileReplacementError.originalLeftInArchive(let archive, _) {
            #expect(archive == "_Replaced/shows/a.mp4")
        }
        #expect(f.read("_Replaced/shows/a.mp4") == "original")
    }

    @Test func aFailedLandingRestoresTheOriginalWhenItCan() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        _ = try f.write("shows/a.mkv", "original")
        let result = try f.write("work/result.mp4", "remuxed")

        #expect(throws: FileReplacementError.self) {
            try LibraryDatabase.replaceFile(
                under: f.root, currentRelative: "shows/a.mkv", newRelative: "shows/a.mp4",
                with: result, fileAccess: FailingMoves(failMovesTo: "/shows/a.mp4"))
        }
        // The landing failed; the item's file is back where its row says.
        #expect(f.read("shows/a.mkv") == "original")
        #expect(f.read("_Replaced/shows/a.mkv") == nil)
    }

    @Test func theWorkingFileIsOnTheSameVolumeAsTheFileItReplaces() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let target = try f.write("shows/a.mkv", "original")

        let working = try LibraryDatabase.workingURL(toReplace: target, fileExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: working.deletingLastPathComponent()) }

        let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        #expect(try volume(working.deletingLastPathComponent()) == volume(target))
        #expect(working.pathExtension == "mp4")
    }
}
