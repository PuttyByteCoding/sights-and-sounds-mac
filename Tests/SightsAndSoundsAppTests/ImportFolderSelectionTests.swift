import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The Import window's rail. Clicking a folder's name is how the flow
/// goes from one folder to the next — pick a folder, stage its tags,
/// import it, pick the next — and the click used to tick the folder only
/// while nothing else was ticked: with one folder already in scope, a
/// click on another folder highlighted it and the table went on showing
/// the first folder's files, so the folder picked did not show its files.
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

    @Test func clickingAFolderShowsThatFolderAlone() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        #expect(selection.focused == "shows")
        #expect(selection.checked == ["shows"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])

        // The next folder replaces the first: its files are what the
        // table shows and what Import would take.
        selection.click("audio", in: outcome)
        #expect(selection.focused == "audio")
        #expect(selection.checked == ["audio"])
        #expect(selection.paths == ["audio/b.m4a"])
    }

    @Test func tickingAddsAFolderToTheScopeAndUntickingTakesItOut() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.toggle("audio", in: outcome)
        #expect(selection.checked == ["shows", "audio"])
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4", "audio/b.m4a"])
        #expect(selection.focused == "shows", "ticking is not focusing")

        selection.toggle("shows", in: outcome)
        #expect(selection.checked == ["audio"])
        #expect(selection.paths == ["audio/b.m4a"])
    }

    @Test func clickingAFolderWithNothingNewStillShowsIt() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.click("shows/1996", in: outcome)
        #expect(selection.checked == ["shows/1996"], "the table should show the folder's known files")
        #expect(selection.paths.isEmpty)
    }

    @Test func aFileUntickedByHandStaysOutUntilItsFolderIsClickedAgain() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.toggleFile("shows/1995/d1.mp4")
        #expect(selection.paths == ["shows/1995/disc2/d2.mp4"])
        selection.toggleFile("shows/1995/d1.mp4")
        #expect(selection.paths == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])
    }

    @Test func anImportedFolderLeavesTheScopeAndTheOthersStay() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.toggle("audio", in: outcome)
        let imported = outcome.newPaths(under: "shows")
        selection.afterImport(imported, updated: outcome.markingKnown(imported))
        #expect(selection.checked == ["audio"])
        #expect(selection.paths == ["audio/b.m4a"])
    }

    @Test func aRescanStartsOverWithTheFirstFolderFocused() {
        var selection = ImportFolderSelection()
        selection.click("shows", in: outcome)
        selection.reset(focusing: "audio")
        #expect(selection == ImportFolderSelection(focused: "audio"))
        #expect(selection.checked.isEmpty && selection.paths.isEmpty)
    }
}
