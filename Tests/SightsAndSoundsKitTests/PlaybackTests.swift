import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 3b kit logic: the ported keyboard map, waveform downsampling,
/// and playback progress recording.
@Suite struct PlaybackTests {

    // MARK: Keyboard map (ported decision table from playerKeyboard.ts)

    private let settings = SkipSettings(
        key1Seconds: 1, key3Seconds: 3, key4Seconds: 4,
        key6Seconds: 6, key7Seconds: 7, key9Seconds: 9)

    private func action(_ ch: Character, shift: Bool = false, numpad: Bool = false) -> PlayerAction? {
        PlayerKeyMap.action(character: ch, shift: shift, numpad: numpad, settings: settings)
    }

    @Test func digitSeekTable() {
        // 1/4/7 back, 3/6/9 forward, per settings.
        #expect(action("1") == .seek(seconds: -1))
        #expect(action("3") == .seek(seconds: 3))
        #expect(action("4") == .seek(seconds: -4))
        #expect(action("6") == .seek(seconds: 6))
        #expect(action("7") == .seek(seconds: -7))
        #expect(action("9") == .seek(seconds: 9))
        #expect(action("5") == .playPause)
        #expect(action("0") == .seekToStart)
        #expect(action("8") == .seekToNearEnd)
        #expect(action("2") == nil)
    }

    @Test func shiftedGlyphsMapToTheirDigits() {
        // Layouts where Shift+digit types a glyph still seek.
        #expect(action("!", shift: true) == .seek(seconds: -1))
        #expect(action("#", shift: true) == .seek(seconds: 3))
        #expect(action("$", shift: true) == .seek(seconds: -4))
        #expect(action("^", shift: true) == .seek(seconds: 6))
        #expect(action("&", shift: true) == .seek(seconds: -7))
        #expect(action("(", shift: true) == .seek(seconds: 9))
    }

    @Test func numpadExtrasAndSpace() {
        #expect(action("-", numpad: true) == .seekToNearEnd)
        #expect(action("-") == nil)  // top-row minus does nothing
        #expect(action(" ") == .playPause)
        #expect(action(" ", shift: true) == nil)  // Shift+Space reserved (analyze, Phase 4)
    }

    @Test func flagToggleLetters() {
        #expect(action("f") == .toggleFavorite)
        #expect(action("F") == .toggleFavorite)
        #expect(action("r") == .toggleNeedsReview)
        #expect(action("d") == .toggleMarkedForDeletion)
        #expect(action("w") == .togglePlaybackIssue)
        #expect(action("x") == nil)
        // Shift+letter is not a binding (matches the old guard).
        #expect(action("f", shift: true) == nil)
    }

    @Test func defaultSkipDistancesMatchTheOldApp() {
        let defaults = SkipSettings()
        #expect(defaults.key1Seconds == 2 && defaults.key4Seconds == 30 && defaults.key7Seconds == 240)
    }

    // MARK: Waveform math

    @Test func peaksBucketAndNormalize() {
        let samples: [Float] = [0.1, -0.5, 0.2, 0.25, -1.0, 0.3, 0.0, 0.4]
        let peaks = WaveformMath.peaks(samples: samples, bucketCount: 4)
        // Buckets: [0.1,0.5] [0.2,0.25] [1.0,0.3] [0.0,0.4] → peaks then /1.0
        #expect(peaks == [0.5, 0.25, 1.0, 0.4])
    }

    @Test func peaksEdgeCases() {
        #expect(WaveformMath.peaks(samples: [], bucketCount: 100) == [])
        #expect(WaveformMath.peaks(samples: [0.5], bucketCount: 0) == [])
        // Silence stays zeros (no divide-by-zero).
        #expect(WaveformMath.peaks(samples: [0, 0, 0, 0], bucketCount: 2) == [0, 0])
        // Fewer samples than buckets: one bucket per sample.
        #expect(WaveformMath.peaks(samples: [0.5, 1.0], bucketCount: 10).count == 2)
    }

    // MARK: Progress recording

    private func makeItem() throws -> (FilterFixture, UUID) {
        let f = try FilterFixture()
        return (f, f.show1995.id)
    }

    private func reload(_ f: FilterFixture, _ id: UUID) throws -> MediaItem {
        try f.library.writer.read { try MediaItem.fetchOne($0, key: id)! }
    }

    @Test func stopRecordsResumeInTheMiddle() throws {
        let (f, id) = try makeItem()
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 600, durationSeconds: 3600)
        let item = try reload(f, id)
        #expect(item.resumePositionSeconds == 600)
        #expect(item.lastWatchedAt != nil)
    }

    @Test func stopNearEitherEdgeClearsResume() throws {
        let (f, id) = try makeItem()
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 600, durationSeconds: 3600)

        // Under 15s in: cleared.
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 10, durationSeconds: 3600)
        #expect(try reload(f, id).resumePositionSeconds == nil)

        // Past 95%: cleared.
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 600, durationSeconds: 3600)
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 3540, durationSeconds: 3600)
        #expect(try reload(f, id).resumePositionSeconds == nil)

        // Unknown duration: only the 15-second floor applies.
        try f.library.recordPlaybackStop(itemID: id, positionSeconds: 600, durationSeconds: nil)
        #expect(try reload(f, id).resumePositionSeconds == 600)
    }

    @Test func completionTalliesAndMarks() throws {
        let (f, id) = try makeItem()
        try f.library.recordPlaybackCompletion(itemID: id)
        try f.library.recordPlaybackCompletion(itemID: id)
        let item = try reload(f, id)
        #expect(item.watchCount == 2)
        #expect(item.completed)
    }

    @Test func flagTogglesFlipAndReport() throws {
        let (f, id) = try makeItem()
        #expect(try f.library.toggleFlag(.favorite, itemID: id) == true)
        #expect(try f.library.toggleFlag(.favorite, itemID: id) == false)
        #expect(try f.library.toggleFlag(.playbackIssue, itemID: id) == true)
        #expect(try reload(f, id).playbackIssue)
    }
}
