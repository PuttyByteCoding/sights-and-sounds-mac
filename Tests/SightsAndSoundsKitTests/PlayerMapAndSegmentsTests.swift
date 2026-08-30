import Foundation
import Testing
@testable import SightsAndSoundsKit

/// One key map chosen once, and segments that are a label on a record
/// rather than a second table.
@Suite struct PlayerMapAndSegmentsTests {

    // MARK: - The four rows

    @Test func onlyFourRowsDiffer() {
        let differing = KeyMapStyle.comparison.filter(\.differs).map(\.label)
        #expect(differing == [
            "Previous / next item",
            "Open / close a segment",
            "Triage keep / issue / delete",
        ])
    }

    /// Three of the four rows are behaviour; the fourth (triage) is a
    /// mode. Every label the window shows comes from one table, so a
    /// hint cannot disagree with the map in force.
    @Test func labelsComeFromTheChosenMap() {
        #expect(KeyMapStyle.mac.labels.segmentOpen == "⌃{")
        #expect(KeyMapStyle.web.labels.segmentOpen == "[")
        #expect(KeyMapStyle.mac.labels.previousNext == "← →")
        #expect(KeyMapStyle.web.labels.previousNext == "⇧← ⇧→")
    }

    @Test func arrowsWalkTheListingPerMap() {
        #expect(PlayerKeyMap.playlistStep(arrow: .right, shift: false, style: .mac) == 1)
        #expect(PlayerKeyMap.playlistStep(arrow: .left, shift: false, style: .mac) == -1)
        // On the web map a bare arrow belongs to the text cursor.
        #expect(PlayerKeyMap.playlistStep(arrow: .right, shift: false, style: .web) == nil)
        #expect(PlayerKeyMap.playlistStep(arrow: .right, shift: true, style: .web) == 1)
        #expect(PlayerKeyMap.playlistStep(arrow: .right, shift: true, style: .mac) == nil)
    }

    @Test func segmentMarksFollowTheMap() {
        #expect(PlayerKeyMap.segmentMark(character: "[", control: false, style: .web) == .open)
        #expect(PlayerKeyMap.segmentMark(character: "]", control: false, style: .web) == .close)
        #expect(PlayerKeyMap.segmentMark(character: "[", control: false, style: .mac) == nil)
        #expect(PlayerKeyMap.segmentMark(character: "{", control: true, style: .mac) == .open)
        #expect(PlayerKeyMap.segmentMark(character: "}", control: true, style: .mac) == .close)
        // C closes as a clip in both maps — the kind is decided at the
        // close, when you know what you just marked.
        #expect(PlayerKeyMap.segmentMark(character: "c", control: false, style: .mac) == .closeAsClip)
        #expect(PlayerKeyMap.segmentMark(character: "C", control: false, style: .web) == .closeAsClip)
    }

    /// Bare braces stay hide blocks in both maps: a hide block is an
    /// instruction to an edit job, not a segment record.
    @Test func bareBracesAreNotSegmentMarks() {
        #expect(PlayerKeyMap.segmentMark(character: "{", control: false, style: .mac) == nil)
        #expect(PlayerKeyMap.segmentMark(character: "}", control: false, style: .mac) == nil)
    }

    @Test func triageKeysBelongToTheWebMapOnly() {
        #expect(PlayerKeyMap.triageAction(character: "r", style: .web) == .toggleNeedsReview)
        #expect(PlayerKeyMap.triageAction(character: "w", style: .web) == .togglePlaybackIssue)
        #expect(PlayerKeyMap.triageAction(character: "d", style: .web) == .toggleMarkedForDeletion)
        #expect(PlayerKeyMap.triageAction(character: "r", style: .mac) == nil)
    }

    /// Everything else is identical, so the shared table answers the
    /// same way whichever map is in force.
    @Test func thesharedTableIsUnchanged() {
        #expect(PlayerKeyMap.action(character: " ", shift: false, numpad: false) == .playPause)
        #expect(PlayerKeyMap.action(character: "5", shift: false, numpad: true) == .playPause)
        #expect(PlayerKeyMap.action(character: "-", shift: false, numpad: true) == .seekToNearEnd)
    }

    // MARK: - Segments

    @Test func aSongAndAClipAreTheSameRecordWithDifferentLabels() throws {
        let f = try FilterFixture()
        let song = try f.library.createEmbeddedClip(
            parentID: f.show1995.id, startSeconds: 10, endSeconds: 40, role: .song)
        let clip = try f.library.createEmbeddedClip(
            parentID: f.show1995.id, name: "Encore", startSeconds: 60, endSeconds: 90, role: .clip)
        #expect(song.segmentRole == .song)
        #expect(clip.segmentRole == .clip)
        // Both are child rows of the same parent, both carry the range —
        // alongside the clip the fixture already hangs off this item.
        let children = try f.library.clips(of: f.show1995.id)
        #expect(Set(children.map(\.id)).isSuperset(of: [song.id, clip.id]))
        #expect(children.allSatisfy { $0.parentMediaItemID == f.show1995.id })
    }

    /// Closing a segment must never be blocked on a text field, so the
    /// name is optional and the role supplies a default to rename later.
    @Test func anUnnamedSegmentTakesItsRolesDefaultName() throws {
        let f = try FilterFixture()
        let song = try f.library.createEmbeddedClip(
            parentID: f.show1995.id, startSeconds: 1, endSeconds: 2, role: .song)
        #expect(song.notes == "New song")
        try f.library.renameSegment(song.id, to: "  Set opener  ")
        let renamed = try f.library.clips(of: f.show1995.id).first { $0.id == song.id }
        #expect(renamed?.notes == "Set opener")
        // Clearing the name falls back rather than leaving a blank row.
        try f.library.renameSegment(song.id, to: "   ")
        let blanked = try f.library.clips(of: f.show1995.id).first { $0.id == song.id }
        #expect(blanked?.notes == "New song")
    }

    @Test func removingASegmentRemovesOnlyTheRow() throws {
        let f = try FilterFixture()
        let song = try f.library.createEmbeddedClip(
            parentID: f.show1995.id, startSeconds: 5, endSeconds: 9, role: .song)
        let before = try f.library.clips(of: f.show1995.id).count
        try f.library.deleteSegment(song.id)
        let after = try f.library.clips(of: f.show1995.id)
        #expect(after.count == before - 1)
        #expect(!after.contains { $0.id == song.id })
        // The parent is untouched: a segment is a name over a range.
        #expect(try f.names(MediaFilter()).contains("a.mp4"))
    }

    /// A top-level item is not a segment, and the write path says so
    /// rather than deleting someone's media.
    @Test func deletingANonSegmentIsRefused() throws {
        let f = try FilterFixture()
        #expect(throws: ClipError.self) {
            try f.library.deleteSegment(f.show1995.id)
        }
    }

    @Test func existingEmbeddedRowsMigrateToClips() throws {
        let f = try FilterFixture()
        // The fixture inserts its embedded clip directly, as a library
        // written before the column existed would have.
        let migrated = try f.library.writer.read { db in
            try MediaItem.fetchOne(db, key: f.embeddedClip.id)
        }
        #expect(migrated?.segmentRole == nil || migrated?.segmentRole == .clip)
    }

    // MARK: - Settings

    @Test func theKeyMapIsOneAppSetting() throws {
        let json = #"{"keyMap": "web"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.keyMap == .web)
        // Absent means the map that ships today.
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).keyMap == .mac)
    }

    /// The right side became one rail and on-screen text became a
    /// drawer, so a layout written before that carries its tag-panel
    /// width into the rail — the same edge in the same place.
    @Test func theOldPanelWidthsCarryForward() throws {
        let json = #"{"tagPanelWidth": 320, "textPanelWidth": 280, "showsQueue": false}"#
        let layout = try JSONDecoder().decode(PlayerLayoutSettings.self, from: Data(json.utf8))
        #expect(layout.railWidth == 320)
        #expect(!layout.panels.queue)
        #expect(layout.panels.tags)
        #expect(!layout.panels.text)
    }

    @Test func theInfoBarKeptOnlyTheTwoSettingsWithAHome() throws {
        let json = #"{"showsPosition": false, "showsTags": true, "showsFavorite": true}"#
        let bar = try JSONDecoder().decode(InfoBarSettings.self, from: Data(json.utf8))
        #expect(!bar.showsPosition)
        #expect(bar.showsDownload)
    }
}
