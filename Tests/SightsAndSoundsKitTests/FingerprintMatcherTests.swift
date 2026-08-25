import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The ported matcher against the old app's hand-built-array test matrix —
/// same scenarios, same gates, same survey-derived thresholds.
@Suite struct FingerprintMatcherTests {

    private let rate = 8.0  // MatchTunables' default granularity

    /// Deterministic random-looking sub-fingerprints; distinct seeds never
    /// share state (the old suite once had a seed-collapse bug — SplitMix64
    /// streams are independent per seed by construction).
    private func pattern(seed: UInt64, length: Int) -> [Int32] {
        var rng = DemoVocabulary.SeededGenerator(seed: seed)
        return (0..<length).map { _ in Int32(truncatingIfNeeded: rng.next()) }
    }

    private func duration(_ length: Int) -> Double { Double(length) / rate }

    /// Flip an exact fraction of total bits so the BER against the
    /// original is known exactly.
    private func corrupt(_ fp: [Int32], fraction: Double, seed: UInt64) -> [Int32] {
        let totalBits = fp.count * 32
        let flips = Int((fraction * Double(totalBits)).rounded())
        var indices = Array(0..<totalBits)
        var rng = DemoVocabulary.SeededGenerator(seed: seed)
        for i in stride(from: indices.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            indices.swapAt(i, j)
        }
        var result = fp
        for k in 0..<flips {
            let bit = indices[k]
            result[bit / 32] ^= Int32(bitPattern: 1 << UInt32(bit % 32))
        }
        return result
    }

    @Test func identicalArraysMatchPerfectlyAsSameRecording() {
        let fp = pattern(seed: 1, length: 400)  // 50s
        let match = FingerprintMatcher.match(fp, durationA: duration(400), fp, durationB: duration(400))
        #expect(match != nil)
        #expect(match!.similarity > 0.999)
        #expect(match!.offsetSeconds == 0)
        #expect(!match!.isContainment)
    }

    @Test func shiftedCopyDetectsTheOffset() {
        let core = pattern(seed: 2, length: 400)
        // b = 10s of unrelated noise, then the core content.
        let noise = pattern(seed: 3, length: 80)
        let b = noise + core
        let match = FingerprintMatcher.match(
            core, durationA: duration(core.count), b, durationB: duration(b.count))
        #expect(match != nil)
        // a's start aligns 10s into b → positive offset.
        #expect(abs(match!.offsetSeconds - 10.0) < 1.0)
        // 50s overlap covers ≥80% of both durations (50s, 60s) — same
        // recording, matching the old suite's expectation.
        #expect(!match!.isContainment)
    }

    @Test func shortSubsetInsideLongArrayIsContainment() {
        let long = pattern(seed: 4, length: 1600)  // 200s
        let subset = Array(long[400..<720])        // 40s slice starting at 50s
        let match = FingerprintMatcher.match(
            subset, durationA: duration(subset.count), long, durationB: duration(long.count))
        #expect(match != nil)
        #expect(match!.isContainment)
        #expect(abs(match!.offsetSeconds - 50.0) < 1.0)
        #expect(abs(match!.overlapSeconds - 40.0) < 1.0)
    }

    @Test func unrelatedArraysDoNotMatch() {
        let a = pattern(seed: 5, length: 800)
        let b = pattern(seed: 6, length: 800)
        #expect(FingerprintMatcher.match(a, durationA: duration(800), b, durationB: duration(800)) == nil)
    }

    @Test func corruptionBelowTheGateStillMatches() {
        let a = pattern(seed: 7, length: 400)
        let b = corrupt(a, fraction: 0.20, seed: 8)  // BER 0.20 < 0.30 gate
        let match = FingerprintMatcher.match(a, durationA: duration(400), b, durationB: duration(400))
        #expect(match != nil)
        #expect(abs(match!.similarity - 0.80) < 0.02)
    }

    @Test func corruptionAboveTheGateDoesNotMatch() {
        let a = pattern(seed: 9, length: 400)
        let b = corrupt(a, fraction: 0.40, seed: 10)  // BER 0.40 > 0.30 gate
        #expect(FingerprintMatcher.match(a, durationA: duration(400), b, durationB: duration(400)) == nil)
    }

    @Test func overlapShorterThanTheFloorDoesNotMatch() {
        // Identical 20s arrays: below the 25s measured reliability floor.
        let fp = pattern(seed: 11, length: 160)
        #expect(FingerprintMatcher.match(fp, durationA: duration(160), fp, durationB: duration(160)) == nil)
    }

    @Test func smallSharedSliceFailsTheFractionGate() {
        // 30s shared slice inside two otherwise-unrelated 200s files:
        // overlap (30s) < 0.60 × min duration (200s) → rejected.
        let shared = pattern(seed: 12, length: 240)
        let a = pattern(seed: 13, length: 1360) + shared
        let b = shared + pattern(seed: 14, length: 1360)
        #expect(FingerprintMatcher.match(
            a, durationA: duration(a.count), b, durationB: duration(b.count)) == nil)
    }

    @Test func tinyPerfectAlignmentCannotShadowTheTrueMatch() {
        // The survey-hardened regression: constant-valued runs (digital
        // silence) offer a tiny overlap at similarity 1.0; the genuine
        // alignment has slightly lower similarity over a large overlap.
        // The in-loop floor keeps the tiny one out of the running.
        let silence = [Int32](repeating: 0, count: 40)  // 5s of "silence"
        let core = pattern(seed: 15, length: 800)       // 100s of content
        let a = silence + corrupt(core, fraction: 0.05, seed: 16)
        let b = silence + core
        let match = FingerprintMatcher.match(
            a, durationA: duration(a.count), b, durationB: duration(b.count))
        #expect(match != nil)
        #expect(match!.overlapSeconds > 90)  // the real alignment won
    }

    @Test func bucketKeysSeparateIdenticalFromUnrelated() {
        let a = pattern(seed: 17, length: 2400)  // 300s — realistic length
        let b = pattern(seed: 18, length: 2400)
        let keysA = Set(FingerprintMatcher.bucketKeys(a, maskBits: FingerprintMatcher.sweepMaskBits))
        let keysB = Set(FingerprintMatcher.bucketKeys(b, maskBits: FingerprintMatcher.sweepMaskBits))
        let selfShared = keysA.intersection(keysA).count
        let crossShared = keysA.intersection(keysB).count
        #expect(selfShared == keysA.count)
        // Unrelated pairs stay under the calibrated relative gate.
        let threshold = FingerprintMatcher.sweepThreshold(
            distinctA: keysA.count, distinctB: keysB.count)
        #expect(crossShared < threshold)
    }

    @Test func sweepThresholdClampsMisconfiguration() {
        // A fraction > 1 or negative floor must never silently disable
        // matching (the old app's documented failure modes).
        #expect(FingerprintMatcher.sweepThreshold(
            minSharedBucketKeys: -1, minSharedBucketKeyFraction: 5.0,
            distinctA: 100, distinctB: 100) == 100)
        #expect(FingerprintMatcher.sweepThreshold(
            minSharedBucketKeys: 2, minSharedBucketKeyFraction: -0.5,
            distinctA: 100, distinctB: 100) == 2)
    }

    @Test func packRoundTrip() {
        let values: [Int32] = [0, -1, Int32.max, Int32.min, 12345]
        let record = AudioFingerprintRecord(
            mediaItemID: UUID(), durationSeconds: 1,
            fingerprint: AudioFingerprintRecord.pack(values), toolVersion: "test")
        #expect(record.unpacked == values)
    }
}
