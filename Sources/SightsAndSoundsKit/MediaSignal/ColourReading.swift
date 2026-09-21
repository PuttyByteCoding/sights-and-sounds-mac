import Accelerate
import Foundation

/// What the samples themselves say about range, depth and colour, to set
/// beside what the file's tags claim.
///
/// A transcoder writes tags from its settings, not from the picture. A
/// full-range picture tagged video-range plays crushed; an 8-bit master
/// re-encoded as 10-bit gains two bits of nothing; a VHS capture has a
/// tenth of the colour detail its 4:2:0 container could hold. All three
/// are read here from the planes.
public enum ColourReading {
    public static func measure(_ frames: [PictureFrame], in area: PictureGeometry.ActiveArea) -> SignalFindings {
        var findings = SignalFindings()
        guard !frames.isEmpty else { return findings }

        var lows: [(Double, Double)] = [], highs: [(Double, Double)] = []
        var below: [Double] = [], above: [Double] = []
        var saturations: [(Double, Double)] = []
        var fractional: [Double] = []

        for frame in frames {
            let samples = activeLuma(frame, in: area)
            guard samples.count >= 256 else { continue }
            let sorted = samples.sorted()
            // The extremes that a thousandth of the picture reaches; the
            // single darkest pixel is noise or a ringing edge.
            lows.append((frame.positionSeconds, Double(sorted[sorted.count / 1000])))
            highs.append((frame.positionSeconds, Double(sorted[sorted.count - 1 - sorted.count / 1000])))
            below.append(Double(sorted.prefix { $0 < 15.5 }.count) / Double(sorted.count))
            above.append(Double(sorted.reversed().prefix { $0 > 235.5 }.count) / Double(sorted.count))

            if frame.bitDepth > 8 {
                // Ten-bit codes sit on quarter steps of the 8-bit scale.
                // Content that was only ever 8-bit lands on whole numbers.
                let offWhole = samples.count { abs($0 - $0.rounded()) > 0.01 }
                fractional.append(Double(offWhole) / Double(samples.count))
            }
            if !frame.cb.isEmpty {
                let cb = vDSP.add(-128, frame.cb), cr = vDSP.add(-128, frame.cr)
                let magnitude = vForce.sqrt(vDSP.add(vDSP.multiply(cb, cb), vDSP.multiply(cr, cr)))
                saturations.append((frame.positionSeconds, Double(vDSP.mean(magnitude))))
            }
        }
        guard !lows.isEmpty else { return findings }

        FrameSummary.record("colour.lumaLow", lows, into: &findings)
        FrameSummary.record("colour.lumaHigh", highs, into: &findings)
        let lowest = lows.map(\.1).min() ?? 16, highest = highs.map(\.1).max() ?? 235
        findings.measure("colour.lumaLowest", lowest)
        findings.measure("colour.lumaHighest", highest)
        findings.measure("colour.belowVideoBlackShare", FrameSummary.percentile(below, 0.9))
        findings.measure("colour.aboveVideoWhiteShare", FrameSummary.percentile(above, 0.9))
        // Video range keeps to 16...235 with a little over- and undershoot.
        // Reaching well outside it, in more than one frame, is full range.
        let outside = zip(lows, highs).count { $0.1 < 8 || $1.1 > 245 }
        findings.measure("colour.usesFullRange", outside >= 2 ? 1 : 0)
        // A picture that never gets near black or white has been lifted or
        // flattened: usually a range conversion applied twice.
        findings.measure("colour.washedOut", lowest > 30 && highest < 220 ? 1 : 0)

        if !fractional.isEmpty {
            findings.measure("colour.lowBitsUsedShare", FrameSummary.percentile(fractional, 0.5))
        }
        if !saturations.isEmpty {
            FrameSummary.record("colour.saturation", saturations, into: &findings)
            let typical = FrameSummary.percentile(saturations.map(\.1), 0.9) ?? 0
            findings.measure("colour.monochrome", typical < 2.5 ? 1 : 0)
        }
        return findings
    }

    static func activeLuma(_ frame: PictureFrame, in area: PictureGeometry.ActiveArea) -> [Float] {
        guard area.left + area.width <= frame.width, area.top + area.height <= frame.height else {
            return frame.luma
        }
        // Every other row and column: a quarter of the samples says the
        // same thing about a histogram.
        var samples: [Float] = []
        samples.reserveCapacity(area.width * area.height / 4)
        for row in stride(from: area.top, to: area.top + area.height, by: 2) {
            for column in stride(from: area.left, to: area.left + area.width, by: 2) {
                samples.append(frame.luma[row * frame.width + column])
            }
        }
        return samples
    }
}

/// How much detail the colour carries next to the brightness.
///
/// 4:2:0 allows colour half the luma's detail each way. Consumer tape
/// recorded colour at around forty lines across, a small fraction of even
/// its own soft luma, and DV's 4:1:1 halves the horizontal figure again.
/// The shortfall survives any number of re-encodes.
public enum ChromaReading {
    public static func measure(_ frames: [PictureFrame], in area: PictureGeometry.ActiveArea) -> SignalFindings {
        var findings = SignalFindings()
        var across: [(Double, Double)] = [], down: [(Double, Double)] = []
        var offsets: [Double] = []
        var limited = 0, read = 0
        for frame in frames where frame.chromaWidth > 0 && !frame.cb.isEmpty {
            let scaleX = Double(frame.chromaWidth) / Double(frame.width)
            let scaleY = Double(frame.chromaHeight) / Double(frame.height)
            let chromaArea = PictureGeometry.ActiveArea(
                left: Int((Double(area.left) * scaleX).rounded(.up)),
                top: Int((Double(area.top) * scaleY).rounded(.up)),
                width: Int(Double(area.width) * scaleX) - 1, height: Int(Double(area.height) * scaleY) - 1)
            guard chromaArea.width >= 64, chromaArea.height >= 64 else { continue }

            // Whichever colour plane has more going on in this frame.
            let planes = [frame.cb, frame.cr].map {
                PictureFrame(width: frame.chromaWidth, height: frame.chromaHeight, luma: $0)
            }
            let widths = planes.compactMap { DetailSpectrum.horizontal($0, in: chromaArea) }
            let heights = planes.compactMap { DetailSpectrum.vertical($0, in: chromaArea) }
            read += widths.count
            limited += widths.count { $0.noiseLimited }
            if let best = widths.filter({ !$0.noiseLimited }).map(\.effectiveFraction).max() {
                across.append((frame.positionSeconds, best))
            }
            if let best = heights.filter({ !$0.noiseLimited }).map(\.effectiveFraction).max() {
                down.append((frame.positionSeconds, best))
            }
            if let offset = horizontalOffset(frame, in: chromaArea) { offsets.append(offset) }
        }
        if read > 0 { findings.measure("chroma.noiseLimitedShare", Double(limited) / Double(read)) }
        // As for luma: when most readings lie in the noise, none is given.
        if limited * 2 > read {
            across = []
            down = []
        }
        // As a share of what the chroma planes could hold.
        FrameSummary.record("chroma.horizontalFill", across, into: &findings)
        FrameSummary.record("chroma.verticalFill", down, into: &findings)
        if let wide = FrameSummary.percentile(across.map(\.1), 0.9),
           let tall = FrameSummary.percentile(down.map(\.1), 0.9), tall > 0 {
            findings.measure("chroma.horizontalToVerticalFill", wide / tall)
        }
        if offsets.count >= 3 {
            findings.measure("chroma.horizontalOffsetSamples", FrameSummary.percentile(offsets, 0.5))
        }
        return findings
    }

    /// How far, in chroma samples, the colour edges sit from the luma
    /// edges they belong to. Tape delays colour relative to brightness, and
    /// the picture's colours hang off the right-hand side of things.
    static func horizontalOffset(_ frame: PictureFrame, in area: PictureGeometry.ActiveArea) -> Double? {
        let factor = frame.width / max(frame.chromaWidth, 1)
        let rowFactor = frame.height / max(frame.chromaHeight, 1)
        guard factor >= 1, rowFactor >= 1 else { return nil }
        let reach = 4
        var scores = [Double](repeating: 0, count: reach * 2 + 1)
        var lumaRow = [Float](repeating: 0, count: area.width)
        for row in stride(from: area.top + area.height / 8, to: area.top + area.height * 7 / 8, by: 6) {
            for column in 0..<area.width {
                // Luma at chroma resolution: the mean of the samples the
                // chroma sample covers.
                let start = (row * rowFactor) * frame.width + (area.left + column) * factor
                var sum: Float = 0
                for step in 0..<factor { sum += frame.luma[start + step] }
                lumaRow[column] = sum / Float(factor)
            }
            let base = row * frame.chromaWidth + area.left
            let chromaRow = Array(frame.cr[base..<base + area.width])
            let lumaEdges = zip(lumaRow.dropFirst(), lumaRow).map { abs($0 - $1) }
            let chromaEdges = zip(chromaRow.dropFirst(), chromaRow).map { abs($0 - $1) }
            for lag in -reach...reach {
                var sum: Float = 0
                for index in reach..<lumaEdges.count - reach {
                    sum += lumaEdges[index] * chromaEdges[index + lag]
                }
                scores[lag + reach] += Double(sum)
            }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        // A parabola through the peak and its neighbours, for the fraction.
        guard best > 0, best < scores.count - 1 else { return Double(best - reach) }
        let left = scores[best - 1], centre = scores[best], right = scores[best + 1]
        let curvature = left - 2 * centre + right
        let fraction = curvature == 0 ? 0 : 0.5 * (left - right) / curvature
        return Double(best - reach) + fraction
    }
}
