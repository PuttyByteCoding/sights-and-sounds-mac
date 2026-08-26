import Foundation

/// Tunable gates for `FingerprintMatcher.match`. **Ported thresholds — do
/// not redesign** (locked guidance): every default below was measured
/// against real-fingerprint surveys in the old app, not guessed.
///
///   - `maxBitErrorRate` 0.30: a 325-unrelated-pair survey put the
///     observed BER floor at 0.3271 with a 3.7% false-positive tail at the
///     originally planned 0.35; zero pairs fell at or below 0.30, while
///     genuine same-audio re-encodes measured BER 0.0.
///   - `minOverlapSeconds` 25: a phase-sensitivity survey showed ~20s
///     containment matches are structurally inseparable from noise in the
///     bucket-key prefilter (shared-key fraction varied 0.22–1.00 with
///     window phase); ≥25s matches were stable at 0.74–0.78. This is the
///     measured reliability floor the brief refers to.
public struct MatchTunables: Sendable, Equatable {
    public var maxBitErrorRate: Double
    public var minOverlapSeconds: Double
    public var minOverlapFractionOfShorter: Double
    public var sameRecordingBothFraction: Double
    /// Chromaprint's default granularity.
    public var subFingerprintsPerSecond: Double

    public init(
        maxBitErrorRate: Double = 0.30,
        minOverlapSeconds: Double = 25,
        minOverlapFractionOfShorter: Double = 0.60,
        sameRecordingBothFraction: Double = 0.80,
        subFingerprintsPerSecond: Double = 8.0
    ) {
        self.maxBitErrorRate = maxBitErrorRate
        self.minOverlapSeconds = minOverlapSeconds
        self.minOverlapFractionOfShorter = minOverlapFractionOfShorter
        self.sameRecordingBothFraction = sameRecordingBothFraction
        self.subFingerprintsPerSecond = subFingerprintsPerSecond
    }
}

/// Offset convention: positive when `b` carries content before the matched
/// region that `a` lacks (a's start aligns `offsetSeconds` into b);
/// negative is the mirror. For the best integer frame offset `s`,
/// a[i] compares against b[i + s]; offsetSeconds = s / rate.
public struct FingerprintMatch: Sendable, Equatable {
    public let similarity: Double
    public let offsetSeconds: Double
    public let overlapSeconds: Double
    /// false = same recording (overlap covers ≥ sameRecordingBothFraction
    /// of BOTH durations).
    public let isContainment: Bool
}

/// Pure, offset-tolerant Hamming-distance matcher over Chromaprint-style
/// packed sub-fingerprint arrays. No I/O — testable without any
/// fingerprint tool and shared unchanged by the sweep job and future
/// tooling. A faithful port of the old app's `FingerprintMatcher`,
/// including its two survey-hardened behaviors:
///
///   1. The overlap floor applies INSIDE the scoring loop, not just to the
///      final winner — leading/trailing digital silence can produce a
///      tiny-overlap alignment with similarity ≈ 1.0 that would otherwise
///      shadow a genuine large-overlap alignment and turn a true match
///      into a false negative.
///   2. Offset voting strides only `b`; `a` is scanned at every frame. If
///      both sides were strided in phase, 7 of 8 possible integer offsets
///      would be invisible to the vote.
public enum FingerprintMatcher {
    /// Alignment-voting granularity — internal knobs, not tunables. The
    /// sweep's PREFILTER deliberately overrides maskBits to 14 (see
    /// `sweepMaskBits`); the internal vote stays at 12. Two independent
    /// constants that share a value by history, not by contract.
    public static let defaultEveryK = 8
    public static let defaultMaskBits = 12

    /// The sweep prefilter's key width: at realistic multi-minute lengths,
    /// 12-bit keys saturate (unrelated pairs measured sharing a 0.44
    /// fraction); at 14 bits the unrelated worst case drops to 0.29 while
    /// genuine matches barely move (1.0 / ~0.77).
    public static let sweepMaskBits = 14

    /// The sweep's gates, calibrated at 14-bit keys: unrelated floor
    /// 0.2922, same-recording 1.0, 60s containment ~0.75–0.78.
    public static let sweepMinSharedBucketKeys = 2
    public static let sweepMinSharedBucketKeyFraction = 0.40

    private static let maxCandidateOffsets = 8
    private static let refineWindowFrames = defaultEveryK

    /// The shared-key floor for one pair, RELATIVE to the smaller
    /// distinct-key count — an absolute floor cannot work once the key
    /// space saturates. Clamped so misconfiguration can never silently
    /// disable matching (a fraction > 1 or a negative floor both used to).
    public static func sweepThreshold(
        minSharedBucketKeys: Int = sweepMinSharedBucketKeys,
        minSharedBucketKeyFraction: Double = sweepMinSharedBucketKeyFraction,
        distinctA: Int, distinctB: Int
    ) -> Int {
        let keys = max(0, minSharedBucketKeys)
        let fraction = min(1.0, max(0.0, minSharedBucketKeyFraction))
        return max(keys, Int((fraction * Double(min(distinctA, distinctB))).rounded(.up)))
    }

    /// Best offset-aligned match between two packed sub-fingerprint
    /// arrays, or nil when either is empty or the best alignment fails a
    /// gate. Inverted-index voting shortlists candidate alignments; exact
    /// popcount BER runs only around those — never O(a·b).
    public static func match(
        _ a: [Int32], durationA: Double,
        _ b: [Int32], durationB: Double,
        tunables t: MatchTunables = MatchTunables()
    ) -> FingerprintMatch? {
        guard !a.isEmpty, !b.isEmpty else { return nil }

        var found = false
        var bestOffset = 0
        var bestOverlap = 0
        var bestSimilarity = -Double.infinity

        // In-loop floor: a degenerate short-overlap alignment never enters
        // the running (survey-hardened behavior #1).
        let minOverlapFrames = t.minOverlapSeconds * t.subFingerprintsPerSecond

        for candidate in candidateOffsets(a, b) {
            for offset in (candidate - refineWindowFrames)...(candidate + refineWindowFrames) {
                let (similarity, overlapLength) = score(a, b, at: offset)
                if overlapLength == 0 { continue }
                if Double(overlapLength) < minOverlapFrames { continue }
                if found && similarity <= bestSimilarity { continue }

                found = true
                bestSimilarity = similarity
                bestOffset = offset
                bestOverlap = overlapLength
            }
        }

        guard found else { return nil }
        guard bestSimilarity >= 1.0 - t.maxBitErrorRate else { return nil }

        let overlapSeconds = Double(bestOverlap) / t.subFingerprintsPerSecond
        guard overlapSeconds >= t.minOverlapSeconds else { return nil }
        guard overlapSeconds >= t.minOverlapFractionOfShorter * min(durationA, durationB)
        else { return nil }

        let isSameRecording = overlapSeconds >= t.sameRecordingBothFraction * durationA
            && overlapSeconds >= t.sameRecordingBothFraction * durationB

        return FingerprintMatch(
            similarity: bestSimilarity,
            offsetSeconds: Double(bestOffset) / t.subFingerprintsPerSecond,
            overlapSeconds: overlapSeconds,
            isContainment: !isSameRecording)
    }

    /// Quantized bucket keys for the inverted-index prefilter. NOTE: at
    /// real lengths the ABSOLUTE shared-key count is not a relatedness
    /// signal (key space saturates) — gate with `sweepThreshold`, which is
    /// relative to each pair's own distinct-key counts.
    public static func bucketKeys(
        _ fp: [Int32], everyK: Int = defaultEveryK, maskBits: Int = defaultMaskBits
    ) -> [UInt32] {
        stride(from: 0, to: fp.count, by: everyK).map { key(fp[$0], maskBits: maskBits) }
    }

    // Inverted-index offset voting — asymmetric stride (behavior #2):
    // `b` indexed every defaultEveryK-th frame, `a` scanned fully, so every
    // residue class mod defaultEveryK is tried and the true offset always
    // contributes ~a.count/defaultEveryK votes. Linear, never O(a·b).
    private static func candidateOffsets(_ a: [Int32], _ b: [Int32]) -> [Int] {
        var byKey: [UInt32: [Int]] = [:]
        for j in stride(from: 0, to: b.count, by: defaultEveryK) {
            byKey[key(b[j], maskBits: defaultMaskBits), default: []].append(j)
        }

        var votes: [Int: Int] = [:]
        for i in 0..<a.count {
            guard let js = byKey[key(a[i], maskBits: defaultMaskBits)] else { continue }
            for j in js {
                votes[j - i, default: 0] += 1
            }
        }

        // Offset 0 is always a candidate — a safety net for inputs too
        // short to produce a stride sample.
        if votes[0] == nil { votes[0] = 0 }

        return votes.sorted { $0.value > $1.value }
            .prefix(maxCandidateOffsets)
            .map(\.key)
    }

    // Exact similarity at one integer frame offset over the full overlap:
    // 1.0 − mean Hamming BER (32 bits per sub-fingerprint).
    private static func score(_ a: [Int32], _ b: [Int32], at offset: Int) -> (similarity: Double, overlapLength: Int) {
        let start = max(0, -offset)
        let end = min(a.count, b.count - offset)
        let overlapLength = end - start
        guard overlapLength > 0 else { return (0, 0) }

        var diffBits = 0
        for i in start..<end {
            diffBits += (UInt32(bitPattern: a[i]) ^ UInt32(bitPattern: b[i + offset])).nonzeroBitCount
        }
        return (1.0 - Double(diffBits) / Double(overlapLength * 32), overlapLength)
    }

    /// Top `maskBits` bits, shifted into the low bits — fixed and shared
    /// by voting and the prefilter so keys stay comparable.
    static func key(_ value: Int32, maskBits: Int) -> UInt32 {
        if maskBits >= 32 { return UInt32(bitPattern: value) }
        if maskBits <= 0 { return 0 }
        return UInt32(bitPattern: value) >> (32 - maskBits)
    }
}
