import Foundation

/// When each frame is shown, how big it is, and whether a decoder can
/// start at it: everything the sample table says, with no picture decoded.
public struct FrameSample: Equatable, Sendable {
    public var presentationSeconds: Double
    public var decodeSeconds: Double
    public var byteCount: Int
    public var isKeyframe: Bool

    public init(presentationSeconds: Double, decodeSeconds: Double, byteCount: Int, isKeyframe: Bool) {
        self.presentationSeconds = presentationSeconds
        self.decodeSeconds = decodeSeconds
        self.byteCount = byteCount
        self.isKeyframe = isKeyframe
    }
}

/// The real frame rate and its regularity, the keyframe structure, and how
/// the bits were spent, from a file's frame table.
///
/// The declared frame rate is one number the writer chose. This is what
/// the frames actually do, which is where variable-rate capture, padded
/// low-rate video and a spliced file show themselves.
public enum FrameTiming {
    /// Frame intervals this close to the usual one count as "the same
    /// interval". Container timescales round, and a millisecond timescale
    /// stores 29.97 fps as a mix of 33 and 34 ms, so exact equality would
    /// call most constant-rate files variable.
    static func tolerance(for typical: Double) -> Double { max(typical * 0.02, 0.0011) }

    public static func measure(
        _ samples: [FrameSample], encodedWidth: Int? = nil, encodedHeight: Int? = nil
    ) -> SignalFindings {
        var findings = SignalFindings()
        guard samples.count >= 2 else { return findings }

        let shown = samples.map(\.presentationSeconds).sorted()
        let intervals = zip(shown.dropFirst(), shown).map { $0 - $1 }.filter { $0 > 0 }
        guard !intervals.isEmpty, let first = shown.first, let last = shown.last else { return findings }

        findings.measure("timing.frameCount", Double(samples.count))

        let typical = median(intervals)
        // The last frame is shown for one more interval; without it a
        // two-frame file would have half its real duration.
        let duration = last - first + typical
        findings.measure("timing.durationSeconds", duration)
        let averageRate = Double(samples.count) / duration
        findings.measure("timing.averageFrameRate", averageRate)
        findings.measure("timing.typicalFrameRate", 1 / typical)

        let tolerance = tolerance(for: typical)
        let regular = intervals.count { abs($0 - typical) <= tolerance }
        let regularity = Double(regular) / Double(intervals.count)
        findings.measure("timing.regularIntervalFraction", regularity)
        // 1 = constant frame rate. A handful of odd intervals at a splice
        // does not make a file variable; a tenth of them does.
        findings.measure("timing.constantFrameRate", regularity >= 0.98 ? 1 : 0)
        findings.measure(
            "timing.intervalJitterSeconds", median(intervals.map { abs($0 - typical) }))
        findings.measure("timing.longestIntervalSeconds", intervals.max())
        // Rounded timestamps make any single interval a poor estimate of
        // the rate; over a regular file the average is exact.
        findings.measure(
            "timing.rateFamily", rateFamily(regularity >= 0.98 ? averageRate : 1 / typical)?.rate)

        // Frames stored in a different order from the one they are shown
        // in are what B-frames look like from outside the bitstream.
        let inDecodeOrder = samples.sorted { $0.decodeSeconds < $1.decodeSeconds }
        let reordered = zip(inDecodeOrder.dropFirst(), inDecodeOrder)
            .contains { $0.presentationSeconds < $1.presentationSeconds }
        findings.measure("timing.framesReordered", reordered ? 1 : 0)

        let keyframeTimes = samples.filter(\.isKeyframe).map(\.presentationSeconds).sorted()
        findings.measure("timing.keyframeCount", Double(keyframeTimes.count))
        let keyframeGaps = zip(keyframeTimes.dropFirst(), keyframeTimes).map { $0 - $1 }
        if !keyframeGaps.isEmpty {
            findings.measure("timing.keyframeIntervalSecondsTypical", median(keyframeGaps))
            findings.measure("timing.keyframeIntervalSecondsLongest", keyframeGaps.max())
            findings.measure("timing.keyframeIntervalFramesTypical", median(keyframeGaps) / typical)
        }

        let bytes = samples.reduce(0) { $0 + $1.byteCount }
        let bitrate = Double(bytes) * 8 / duration
        findings.measure("timing.videoBitrate", bitrate)
        if let encodedWidth, let encodedHeight, encodedWidth > 0, encodedHeight > 0 {
            findings.measure(
                "timing.bitsPerPixel",
                bitrate / (Double(encodedWidth) * Double(encodedHeight) * averageRate))
        }
        // How unevenly the bits were spent second by second. A constant
        // bitrate encode sits near zero; constant quality follows the
        // picture and does not.
        findings.measure("timing.bitrateVariation", bitrateVariation(samples, from: first))
        return findings
    }

    /// The broadcast and film rates a measured rate may belong to.
    public static func rateFamily(_ rate: Double) -> (name: String, rate: Double)? {
        let families: [(String, Double)] = [
            ("23.976", 24000.0 / 1001), ("24", 24), ("25", 25), ("29.97", 30000.0 / 1001),
            ("30", 30), ("50", 50), ("59.94", 60000.0 / 1001), ("60", 60),
        ]
        // 23.976 and 24 are 0.1 % apart, so the window has to be tighter
        // than that to tell them apart at all.
        return families
            .filter { abs($0.1 - rate) / $0.1 < 0.0004 }
            .min { abs($0.1 - rate) < abs($1.1 - rate) }
            .map { (name: $0.0, rate: $0.1) }
    }

    static func bitrateVariation(_ samples: [FrameSample], from start: Double) -> Double? {
        var perSecond: [Int: Int] = [:]
        for sample in samples {
            perSecond[Int(sample.presentationSeconds - start), default: 0] += sample.byteCount
        }
        // The last second is usually partial and would read as a dip.
        let seconds = perSecond.keys.sorted().dropLast().map { Double(perSecond[$0]!) }
        guard seconds.count >= 4 else { return nil }
        let mean = seconds.reduce(0, +) / Double(seconds.count)
        guard mean > 0 else { return nil }
        let variance = seconds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(seconds.count)
        return variance.squareRoot() / mean
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
