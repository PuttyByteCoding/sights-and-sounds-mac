import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Phase 6b: the ported quality-score composition and decide semantics.
@Suite struct CompareTests {

    // MARK: Quality score

    private func item(
        kind: MediaKind, path: String = "x/a.mp4",
        width: Int? = nil, height: Int? = nil, videoCodec: String? = nil,
        audioCodec: String? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil,
        bitrate: Int64? = nil, frameRate: Double? = nil, audioStreams: Int? = 1
    ) -> MediaItem {
        MediaItem(
            sourceID: UUID(), kind: kind, relativePath: path,
            durationSeconds: 3600, width: width, height: height,
            videoCodec: videoCodec, audioCodec: audioCodec,
            frameRate: frameRate, bitrate: bitrate,
            audioStreamCount: audioStreams, sampleRate: sampleRate, bitDepth: bitDepth)
    }

    @Test func losslessAudioBeatsLossy() {
        let flac = QualityScore.compute(for: item(
            kind: .audio, path: "a.flac", audioCodec: "flac",
            sampleRate: 44_100, bitDepth: 16, bitrate: 900_000))
        let mp3 = QualityScore.compute(for: item(
            kind: .audio, path: "a.mp3", audioCodec: "mp3",
            sampleRate: 44_100, bitDepth: nil, bitrate: 128_000))
        #expect(flac.total > mp3.total)
        #expect(flac.components.contains { $0.note?.contains("lossless") == true })
    }

    @Test func hevc4kBeatsLegacySd() {
        let good = QualityScore.compute(for: item(
            kind: .video, width: 3840, height: 2160, videoCodec: "hevc",
            audioCodec: "aac", sampleRate: 48_000, bitrate: 40_000_000, frameRate: 30))
        let bad = QualityScore.compute(for: item(
            kind: .video, width: 640, height: 480, videoCodec: "mpeg4",
            audioCodec: "wma", sampleRate: 22_050, bitrate: 700_000, frameRate: 30))
        #expect(good.total > bad.total + 20)
    }

    @Test func missingSignalScalesInsteadOfCapping() {
        // The scaled-denominator design: no signal analysis → metadata
        // components become 100% of the denominator; a perfect-metadata
        // audio file still scores near 100, not capped at a partial budget.
        let perfect = QualityScore.compute(for: item(
            kind: .audio, path: "a.flac", audioCodec: "flac",
            sampleRate: 96_000, bitDepth: 24, bitrate: 2_000_000))
        #expect(perfect.total == 100)
        #expect(perfect.components.contains { $0.label == "Audio signal" && $0.maxPoints == 0 })
    }

    @Test func signalComponentsScoreWhenPresent() {
        let base = item(kind: .audio, path: "a.flac", audioCodec: "flac",
                        sampleRate: 44_100, bitDepth: 16, bitrate: 900_000)
        // Full spectrum, no clipping.
        let clean = QualityScore.compute(for: base, analysis: QualityAnalysisMetrics(
            audioRolloffHz: 21_000, audioPeakDb: -3, audioRmsDb: -18))
        // Lossy-transcode pattern: lossless codec, gutted spectrum, clipping.
        let suspect = QualityScore.compute(for: base, analysis: QualityAnalysisMetrics(
            audioRolloffHz: 14_000, audioPeakDb: -0.1, audioRmsDb: -8))
        #expect(clean.total > suspect.total)
        #expect(suspect.components.contains {
            $0.note?.contains("likely lossy transcode") == true
        })
        #expect(suspect.components.contains {
            $0.label == "Clipping" && $0.points == 0
        })
    }

    @Test func blockinessAnnotatesButNeverScores() {
        let scored = QualityScore.compute(
            for: item(kind: .video, width: 1920, height: 1080, videoCodec: "h264",
                      audioCodec: "aac", sampleRate: 48_000, bitrate: 8_000_000, frameRate: 30),
            analysis: QualityAnalysisMetrics(videoBlockiness: 110, videoBlurriness: 2))
        let blockiness = scored.components.first { $0.label == "Blockiness" }
        #expect(blockiness?.maxPoints == 0)
        #expect(blockiness?.note?.contains("no calibrated scale") == true)
        // Blurriness at goodAt scores full points.
        #expect(scored.components.contains { $0.label == "Blurriness" && $0.points == 10 })
    }

    // MARK: Decide

    private func decideFixture() throws -> (FilterFixture, keeper: MediaItem, loser: MediaItem, candidate: DuplicateCandidate) {
        let f = try FilterFixture()
        // keeper: show1995 (bandA, sbd) — loser: show2001 (bandB).
        let candidate = DuplicateCandidate(
            itemA: f.show1995.id, itemB: f.show2001.id, source: .manual)
        try f.library.writer.write { try candidate.insert($0) }
        return (f, f.show1995, f.show2001, candidate)
    }

    @Test func decideMergesConfirmsAndMarks() throws {
        let (f, keeper, loser, candidate) = try decideFixture()
        let mergeable = try f.library.mergeableTags(keeper: keeper.id, loser: loser.id)
        #expect(mergeable.map(\.name) == ["Band B"])  // multi-value Band merges

        let outcome = try f.library.decide(
            keeper: keeper.id, loser: loser.id,
            candidateID: candidate.id, mergeTagIDs: Set(mergeable.map(\.id)))
        #expect(outcome.tagsMerged == 1)
        #expect(outcome.skippedSingleValue.isEmpty)

        let keeperBands = try f.library.tags(of: keeper.id)
            .first { $0.category.id == f.band.id }?.tags.map(\.name) ?? []
        #expect(Set(keeperBands) == ["Band A", "Band B"])

        let resolved = try f.library.writer.read { try DuplicateCandidate.fetchOne($0, key: candidate.id)! }
        #expect(resolved.status == .confirmed)

        let markedLoser = try f.library.writer.read { try MediaItem.fetchOne($0, key: loser.id)! }
        #expect(markedLoser.markedForDeletion)
        #expect(!markedLoser.needsReview)
    }

    @Test func singleValueCategoryKeeperWins() throws {
        let (f, keeper, loser, _) = try decideFixture()
        // Make Recording Type single-value; give the loser AUD while the
        // keeper holds SBD.
        try f.library.writer.write { db in
            var recType = f.recordingType
            recType.allowMultiple = false
            try recType.update(db)
            try MediaItemTag(mediaItemID: loser.id, tagID: f.aud.id).insert(db)
        }

        // AUD is not mergeable — the keeper's SBD wins.
        let mergeable = try f.library.mergeableTags(keeper: keeper.id, loser: loser.id)
        #expect(!mergeable.contains { $0.id == f.aud.id })

        // Requesting it anyway merges nothing and explains why.
        let outcome = try f.library.decide(
            keeper: keeper.id, loser: loser.id, candidateID: nil,
            mergeTagIDs: [f.aud.id])
        #expect(outcome.tagsMerged == 0)
        #expect(outcome.skippedSingleValue.count == 1)
        #expect(outcome.skippedSingleValue[0].contains("AUD"))
    }

    @Test func twoLoserTagsInOneSingleValueCategoryOnlyFirstMerges() throws {
        let f = try FilterFixture()
        // Keeper has NO recording type; loser has two (multi allowed today,
        // then the category flips single).
        let keeper = f.show2001  // bandB only
        let loser = f.show1995   // bandA + sbd
        try f.library.writer.write { db in
            try MediaItemTag(mediaItemID: loser.id, tagID: f.aud.id).insert(db)
            var recType = f.recordingType
            recType.allowMultiple = false
            try recType.update(db)
        }
        // In-loop claiming: exactly one of SBD/AUD is mergeable.
        let mergeable = try f.library.mergeableTags(keeper: keeper.id, loser: loser.id)
        let recTypeMergeable = mergeable.filter { $0.tagCategoryID == f.recordingType.id }
        #expect(recTypeMergeable.count == 1)
    }

    @Test func keeperMarkedForDeletionIsRefused() throws {
        let (f, keeper, loser, candidate) = try decideFixture()
        try f.library.writer.write { db in
            try db.execute(sql: "UPDATE mediaItem SET markedForDeletion = 1 WHERE id = ?",
                           arguments: [keeper.id])
        }
        #expect(throws: DecideError.keeperMarkedForDeletion) {
            try f.library.decide(
                keeper: keeper.id, loser: loser.id,
                candidateID: candidate.id, mergeTagIDs: [])
        }
    }

    @Test func mismatchedCandidateIsRefused() throws {
        let (f, keeper, _, candidate) = try decideFixture()
        #expect(throws: DecideError.candidateDoesNotLinkPair) {
            try f.library.decide(
                keeper: keeper.id, loser: f.underscoreDir.id,
                candidateID: candidate.id, mergeTagIDs: [])
        }
    }

    @Test func rejectKeepsThePairPermanently() throws {
        let (f, _, _, candidate) = try decideFixture()
        try f.library.rejectCandidate(candidate.id)
        #expect(try f.library.pendingCandidates().isEmpty)
        let row = try f.library.writer.read { try DuplicateCandidate.fetchOne($0, key: candidate.id)! }
        #expect(row.status == .rejected)
    }
}
