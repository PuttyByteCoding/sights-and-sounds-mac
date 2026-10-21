import Foundation
import Testing

@testable import SightsAndSoundsApp

/// A segment row's text, as the rail draws it and as VoiceOver reads
/// it: the range with the length beside it, and the kind spoken rather
/// than badged.
@Suite struct PlayerSegmentRowTests {
    @Test func theRangeCarriesItsDuration() {
        let row = SegmentRow(id: UUID(), kind: .song, name: "Tweezer", start: 12, end: 90)
        #expect(row.rangeText == "0:12–1:30 · 1:18")
    }

    @Test func theAccessibilityLabelNamesKindNameAndRange() {
        let song = SegmentRow(id: UUID(), kind: .song, name: "Tweezer", start: 12, end: 90)
        #expect(song.accessibilityLabel == "Song Tweezer, 0:12–1:30 · 1:18")
        let hide = SegmentRow(id: UUID(), kind: .hide, name: "Hide", start: 0, end: 3661)
        #expect(hide.accessibilityLabel == "Hide block Hide, 0:00–1:01:01 · 1:01:01")
    }

    @Test func onlySongsAndClipsRename() {
        #expect(SegmentRow(id: UUID(), kind: .clip, name: "C", start: 0, end: 1).isRenameable)
        #expect(!SegmentRow(id: UUID(), kind: .hide, name: "H", start: 0, end: 1).isRenameable)
    }
}
