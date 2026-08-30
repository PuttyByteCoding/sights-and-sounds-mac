import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Saying what an operation costs before it runs, and refusing a join
/// before anything is written.
@Suite struct OperationCostTests {

    /// A stream copy writes what it read; only the encode changes size.
    @Test func streamCopyWritesWhatItRead() {
        let estimate = OperationEstimates.streamCopy(sizes: [1_000_000_000, 500_000_000])
        #expect(estimate.filesWritten == 2)
        #expect(estimate.bytesAdded == 1_500_000_000)
        #expect(estimate.seconds > 0)
        #expect(estimate.timeLabel == "of copying")
    }

    @Test func encodeEstimatesFromBitrateAndDuration() {
        // One hour of H.264 at the preset's target rate.
        let estimate = OperationEstimates.encode(
            durations: [3600], targetBitsPerSecond: EncodeJob.Preset.h264.estimatedBitsPerSecond)
        #expect(estimate.filesWritten == 1)
        // ≈ 2.7 GB — the order of magnitude is the point.
        #expect(estimate.bytesAdded > 2_000_000_000)
        #expect(estimate.bytesAdded < 3_500_000_000)
        #expect(estimate.timeLabel == "of encoding")
        // HEVC targets a lower rate, so it predicts a smaller file.
        let hevc = OperationEstimates.encode(
            durations: [3600], targetBitsPerSecond: EncodeJob.Preset.hevc.estimatedBitsPerSecond)
        #expect(hevc.bytesAdded < estimate.bytesAdded)
    }

    @Test func aJoinWritesOneFileFromItsParts() {
        #expect(OperationEstimates.join(sizes: [100, 200, 300]).filesWritten == 1)
        #expect(OperationEstimates.join(sizes: [100, 200, 300]).bytesAdded == 600)
        // One part is not a join.
        #expect(OperationEstimates.join(sizes: [100]).isEmpty)
    }

    /// Block removal writes what it KEEPS — the same ranges that draw
    /// the timeline, so the picture and the number cannot drift.
    @Test func blockRemovalWritesTheKeptShare() {
        let estimate = OperationEstimates.blockRemoval(
            totalSeconds: 100, hiddenSeconds: 25, sourceBytes: 1000)
        #expect(estimate.bytesAdded == 750)
    }

    @Test func clipExportWritesItsShareOfTheParent() {
        let estimate = OperationEstimates.clipExport(
            clipSeconds: 30, parentSeconds: 300, parentBytes: 1000)
        #expect(estimate.bytesAdded == 100)
        #expect(estimate.filesWritten == 1)
    }

    /// OCR writes no file at all; its cost is frames and time.
    @Test func ocrCostsFramesNotBytes() {
        // Four hour-long items at half-second sampling.
        let frames = OperationEstimates.ocrFrames(
            durations: [3600, 3600, 3600, 3600], sampleIntervalSeconds: 0.5)
        #expect(frames == 28_800)
        let estimate = OperationEstimates.ocr(
            durations: [3600], sampleIntervalSeconds: 0.5, level: .accurate)
        #expect(estimate.bytesAdded == 0)
        #expect(estimate.filesWritten == 0)
        // Fast recognition is an order of magnitude quicker.
        let fast = OperationEstimates.ocr(
            durations: [3600], sampleIntervalSeconds: 0.5, level: .fast)
        #expect(fast.seconds < estimate.seconds)
    }

    // MARK: - Join refusal

    /// The refusal has to be visible BEFORE the job is queued, with the
    /// mismatch named — not as a failed row half an hour later.
    @Test func mismatchedPartsAreRefusedWithTheReason() {
        let a = MediaItem(
            sourceID: UUID(), kind: .video, relativePath: "a.mp4",
            width: 1920, height: 1080, videoCodec: "h264")
        var b = a
        b = MediaItem(
            sourceID: a.sourceID, kind: .video, relativePath: "b.mp4",
            width: 1280, height: 720, videoCodec: "hevc")
        let report = JoinJob.compatibility(of: [a, b])
        #expect(!report.isJoinable)
        #expect(report.mismatches.contains { $0.contains("video codec") })
        #expect(report.mismatches.contains { $0.contains("width") })
    }

    @Test func matchingPartsJoin() {
        let a = MediaItem(
            sourceID: UUID(), kind: .video, relativePath: "a.mp4",
            width: 1920, height: 1080, videoCodec: "h264", audioCodec: "aac", sampleRate: 48000)
        let b = MediaItem(
            sourceID: a.sourceID, kind: .video, relativePath: "b.mp4",
            width: 1920, height: 1080, videoCodec: "h264", audioCodec: "aac", sampleRate: 48000)
        #expect(JoinJob.compatibility(of: [a, b]).isJoinable)
    }

    @Test func oneItemIsNotAJoin() {
        let a = MediaItem(sourceID: UUID(), kind: .video, relativePath: "a.mp4")
        let report = JoinJob.compatibility(of: [a])
        #expect(!report.isJoinable)
        #expect(report.mismatches[0].contains("at least 2"))
    }

    // MARK: - OCR settings

    @Test func ocrSettingsDecodeWithTheirDefaults() throws {
        let json = #"{"recognitionLevel": "fast", "collapseRepeats": false}"#
        let settings = try JSONDecoder().decode(OcrSettings.self, from: Data(json.utf8))
        #expect(settings.recognitionLevel == .fast)
        #expect(!settings.collapseRepeats)
        // Untouched keys keep their defaults.
        #expect(settings.minimumTextHeight == OcrSettings().minimumTextHeight)
        #expect(settings.region.isFull)
    }

    @Test func aRegionIsOnlyAppliedWhenItIsNotTheWholeFrame() {
        #expect(OcrSettings.Region.full.isFull)
        #expect(!OcrSettings.Region(x: 0, y: 0.66, width: 1, height: 0.34).isFull)
    }
}
