import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Import window's rail. Several folders can go into one import:
/// clicking a folder's name adds it to the scope, and clicking it again
/// takes it out. A click used to replace the scope with that one folder,
/// so only the small tick box could add a second, which read as "the
/// tree selects one folder".
@Suite struct ImportFolderSelectionTests {
    private func candidate(_ path: String, known: Bool = false) -> ScanCandidate {
        ScanCandidate(
            relativePath: path, folderPath: MediaPath.folder(of: path), fileName: MediaPath.fileName(of: path),
            fileExtension: "mp4", kind: .video, fileSize: 1, isKnown: known, isRemoved: false)
    }

    private var outcome: ScanOutcome {
        ScanOutcome(candidates: [
            candidate("root.mp4", known: true),
            candidate("shows/1995/d1.mp4"),
            candidate("shows/1995/disc2/d2.mp4"),
            candidate("shows/1996/x.mp4", known: true),
            candidate("audio/a.m4a", known: true),
            candidate("audio/b.m4a"),
        ], skippedByExtension: [:], scannedAt: Date())
    }

    @Test func clickingFoldersAddsEachToTheScope() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        #expect(selection.checked == ["shows"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])

        selection.click("audio", in: outcome)
        #expect(selection.checked == ["shows", "audio"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4", "audio/b.m4a"])
    }

    @Test func clickingAFolderInTheScopeTakesItOut() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("audio", in: outcome)
        selection.click("audio", in: outcome)
        #expect(selection.checked == ["shows"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])
    }

    @Test func clickingAFolderWithNothingNewStillShowsIt() {
        var selection = ImportFolderSelection()
        selection.click("shows/1996", in: outcome)
        #expect(selection.checked == ["shows/1996"], "the table should show the folder's known files")
        #expect(selection.paths.isEmpty)
    }

    /// A subfolder taken out of the scope does not take files its parent,
    /// still in the scope, covers.
    @Test func takingOutASubfolderKeepsWhatItsParentCovers() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("shows/1995/disc2", in: outcome)
        selection.click("shows/1995/disc2", in: outcome)
        #expect(selection.checked == ["shows"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])
    }

    @Test func aFileUntickedByHandStaysOutWhenAnotherFolderLeaves() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("audio", in: outcome)
        selection.toggleFile("shows/1995/d1.mp4")
        #expect(selection.paths == ["shows/1995/disc2/d2.mp4", "audio/b.m4a"])
        selection.click("audio", in: outcome)
        #expect(selection.paths == ["shows/1995/disc2/d2.mp4"])
        selection.toggleFile("shows/1995/d1.mp4")
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])
    }

    @Test func clearEmptiesTheScope() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("audio", in: outcome)
        selection.clear()
        #expect(selection.checked.isEmpty && selection.paths.isEmpty)
    }

    @Test func anImportedFolderLeavesTheScopeAndTheOthersStay() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("audio", in: outcome)
        let imported = outcome.newPaths(under: "shows")
        selection.afterImport(imported, updated: outcome.markingKnown(imported))
        #expect(selection.checked == ["audio"])
        #expect(selection.paths == ["audio/b.m4a"])
    }

    @Test func aRescanStartsOver() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.reset()
        #expect(selection == ImportFolderSelection())
        #expect(selection.checked.isEmpty && selection.paths.isEmpty)
    }
}
