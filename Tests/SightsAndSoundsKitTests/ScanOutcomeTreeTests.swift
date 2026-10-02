import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The Update flow's rail: a tree of the source's folders showing only
/// the ones with new files, each counted over its whole subtree, so a
/// folder can be ticked and imported, then the next, with the tree
/// updated in place as files become known.
@Suite struct ScanOutcomeTreeTests {
    private func candidate(_ path: String, known: Bool = false, removed: Bool = false) -> ScanCandidate {
        ScanCandidate(
            relativePath: path, folderPath: MediaPath.folder(of: path), fileName: MediaPath.fileName(of: path),
            fileExtension: "mp4", kind: .video, fileSize: 1, isKnown: known, isRemoved: removed)
    }

    private var outcome: ScanOutcome {
        ScanOutcome(candidates: [
            candidate("root.mp4", known: true),
            candidate("shows/1995/d1.mp4"),
            candidate("shows/1995/disc2/d2.mp4"),
            candidate("shows/1996/x.mp4", known: true),
            candidate("audio/a.m4a", removed: true),
            candidate("audio/b.m4a"),
        ], skippedByExtension: [:], scannedAt: Date())
    }

    @Test func theTreeNestsFoldersAndCountsEachSubtree() {
        let tree = outcome.folderTree(newOnly: false)
        #expect(tree.map(\.name) == ["(root)", "audio", "shows"])
        let shows = tree[2]
        #expect(shows.path == "shows")
        #expect(shows.new == 2 && shows.known == 1 && shows.removed == 0)
        #expect(shows.children.map(\.path) == ["shows/1995", "shows/1996"])
        let y1995 = shows.children[0]
        #expect(y1995.new == 2, "the subfolder's file counts for its parent")
        #expect(y1995.children.map(\.path) == ["shows/1995/disc2"])
        let audio = tree[1]
        #expect(audio.new == 1 && audio.removed == 1)
    }

    @Test func newOnlyPrunesFoldersWithNothingNew() {
        let tree = outcome.folderTree(newOnly: true)
        #expect(tree.map(\.path) == ["audio", "shows"], "the root (all known) should be gone: \(tree.map(\.path))")
        let shows = tree[1]
        #expect(shows.children.map(\.path) == ["shows/1995"], "1996 holds nothing new")
    }

    @Test func pathsUnderAFolderIncludeItsSubfolders() {
        let under = outcome.newPaths(under: "shows")
        #expect(under == ["shows/1995/d1.mp4", "shows/1995/disc2/d2.mp4"])
        #expect(outcome.newPaths(under: "audio") == ["audio/b.m4a"], "a removed file is not new")
        #expect(outcome.newPaths(under: "") == [], "the root means the root folder, not everything")
    }

    @Test func markingKnownUpdatesTheTreeInPlace() {
        let after = outcome.markingKnown(["shows/1995/d1.mp4", "SHOWS/1995/disc2/D2.MP4", "audio/a.m4a"])
        #expect(after.newCount == 1)
        #expect(after.knownCount == 5)
        #expect(after.removedCount == 0, "an imported removed file is known again")
        #expect(after.folderTree(newOnly: true).map(\.path) == ["audio"])
    }
}
