import Accelerate
import Foundation

/// Watches consecutive frames go by and measures what a still cannot
/// show: repeated and blended frames, the comb teeth of interlaced fields
/// stored as one frame, line doubling, the flutter of a bob deinterlacer,
/// and brightness flicker.
///
/// Frames arrive one at a time and only the last two are kept, so a window
/// of any length costs three frames of memory.
public final class SequenceMeter {
    /// A pixel is moving when it changed by more than this since the last
    /// frame. Comb teeth only exist where there is motion, and fine
    /// horizontal texture that is not moving must not be mistaken for them.
    static let motionThreshold: Float = 10
    /// Both vertical neighbours differ from a pixel, the same way, by more
    /// than this: a tooth.
    static let toothThreshold: Float = 14
    /// A frame with this share of its moving pixels in teeth is combed.
    static let combedFrameShare = 0.06

    private var previous: PictureFrame?
    private var beforePrevious: PictureFrame?
    private var previousChange: [Float]?

    private(set) var differences: [Double] = []
    private(set) var combedShares: [Double] = []
    private(set) var blendedFlags: [Bool] = []
    private(set) var linePairAsymmetries: [Double] = []
    private(set) var changeCorrelations: [Double] = []
    private(set) var gradientEnergies: [Double] = []
    private(set) var meanLevels: [Double] = []
    public private(set) var frameCount = 0

    public init() {}

    public func consume(_ frame: PictureFrame) {
        defer {
            beforePrevious = previous
            previous = frame
            frameCount += 1
        }
        meanLevels.append(Double(vDSP.mean(frame.luma)))
        linePairAsymmetries.append(Self.linePairAsymmetry(frame))

        guard let previous, previous.width == frame.width, previous.height == frame.height else { return }
        let change = vDSP.subtract(frame.luma, previous.luma)
        differences.append(Double(vDSP.meanMagnitude(change)))
        combedShares.append(Self.combedShare(frame, change: change))

        // A naive bob deinterlacer shows the two fields as alternate
        // frames, half a line apart, so a still scene flips between two
        // pictures: each change is the last one undone, and the two
        // changes correlate at -1. Independent noise gives -0.5 by
        // construction and motion gives about zero.
        if let previousChange, let correlation = Self.correlation(change, previousChange) {
            changeCorrelations.append(correlation)
        }
        previousChange = change

        gradientEnergies.append(Self.gradientEnergy(frame))

        if let beforePrevious, beforePrevious.width == frame.width, beforePrevious.height == frame.height {
            blendedFlags.append(Self.isBlend(previous.luma, of: beforePrevious.luma, and: frame.luma))
        }
    }

    // MARK: - Per-frame measures

    /// Share of moving pixels that are comb teeth.
    static func combedShare(_ frame: PictureFrame, change: [Float]) -> Double {
        let width = frame.width, height = frame.height
        guard height >= 5 else { return 0 }
        var moving = 0, teeth = 0
        let limit = toothThreshold * toothThreshold
        frame.luma.withUnsafeBufferPointer { luma in
            change.withUnsafeBufferPointer { change in
                for row in 2..<height - 2 {
                    let here = row * width
                    for column in 0..<width where abs(change[here + column]) > motionThreshold {
                        moving += 1
                        let centre = luma[here + column]
                        let above = luma[here - width + column] - centre
                        let below = luma[here + width + column] - centre
                        // A tooth: the lines above and below agree with each
                        // other and both disagree with this one, while the
                        // lines two away, which came from this line's own
                        // field, agree with it. A moving edge fails the
                        // first test and a thin moving line the second.
                        guard above * below > limit, abs(above - below) * 2 < abs(above) + abs(below)
                        else { continue }
                        let reach = (abs(above) + abs(below)) / 4
                        if abs(luma[here - 2 * width + column] - centre) < reach,
                           abs(luma[here + 2 * width + column] - centre) < reach {
                            teeth += 1
                        }
                    }
                }
            }
        }
        // Too little motion to judge is not evidence of anything.
        guard moving > width * height / 200 else { return 0 }
        return Double(teeth) / Double(moving)
    }

    /// Whether rows come in identical pairs. Discarding a field and
    /// doubling the lines of the other makes row 0 equal row 1, row 2 equal
    /// row 3, and so on, so differences within pairs vanish while those
    /// between pairs do not. 0 is an ordinary picture, 1 is line-doubled.
    /// Any later vertical scaling smears the pairs and hides this.
    static func linePairAsymmetry(_ frame: PictureFrame) -> Double {
        let width = frame.width, height = frame.height
        guard height >= 8 else { return 0 }
        var within: Float = 0, between: Float = 0
        frame.luma.withUnsafeBufferPointer { luma in
            var difference = [Float](repeating: 0, count: width)
            for row in stride(from: 0, to: height - 2, by: 2) {
                vDSP_vsub(luma.baseAddress! + (row + 1) * width, 1, luma.baseAddress! + row * width, 1,
                          &difference, 1, vDSP_Length(width))
                within += vDSP.meanMagnitude(difference)
                vDSP_vsub(luma.baseAddress! + (row + 2) * width, 1, luma.baseAddress! + (row + 1) * width, 1,
                          &difference, 1, vDSP_Length(width))
                between += vDSP.meanMagnitude(difference)
            }
        }
        guard within + between > 0 else { return 0 }
        return Double(abs(within - between) / (within + between))
    }

    /// Whether `middle` is a mix of the frames either side of it. Motion
    /// moves edges; a blend shows both positions at once, which is exactly
    /// what a weighted sum of the neighbours predicts and motion does not.
    ///
    /// This finds the blends a frame doubler makes (A, A+B, B, B+C), where
    /// the neighbours are the two sources. It does not find a 24-to-30
    /// blending conversion, where the neighbours are themselves blends of
    /// other frames; measured on a synthetic one it flagged 4 % of frames.
    static func isBlend(_ middle: [Float], of before: [Float], and after: [Float]) -> Bool {
        let span = vDSP.subtract(before, after)
        let spanEnergy = vDSP.sumOfSquares(span)
        // The neighbours have to differ, or anything is a mix of them.
        guard spanEnergy / Float(span.count) > 16 else { return false }
        let offset = vDSP.subtract(middle, after)
        let weight = vDSP.dot(offset, span) / spanEnergy
        guard weight > 0.15, weight < 0.85 else { return false }
        let residual = vDSP.subtract(offset, vDSP.multiply(weight, span))
        return vDSP.sumOfSquares(residual) / spanEnergy < 0.04
    }

    /// Mean size of the step between horizontal neighbours: how sharp the
    /// frame is. A frame made by mixing two others shows every moving edge
    /// twice at half strength and is softer than the frames around it.
    static func gradientEnergy(_ frame: PictureFrame) -> Double {
        guard frame.luma.count > 1 else { return 0 }
        var steps = [Float](repeating: 0, count: frame.luma.count - 1)
        frame.luma.withUnsafeBufferPointer { luma in
            vDSP_vsub(luma.baseAddress!, 1, luma.baseAddress! + 1, 1, &steps, 1, vDSP_Length(steps.count))
        }
        return Double(vDSP.meanMagnitude(steps))
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Double? {
        let energy = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        guard energy > 1e-6 else { return nil }
        return Double(vDSP.dot(a, b) / energy)
    }

    // MARK: - The window's reading

    public struct Reading: Equatable, Sendable {
        public var cadence = CadenceReading.Reading()
        public var blendedFraction = 0.0
        public var combedShareTypical = 0.0
        public var combedShareHigh = 0.0
        public var combedFrameFraction = 0.0
        /// Beat on which combed frames fall: 5 is hard telecine, two combed
        /// frames in every five.
        public var combedPeriod: Int?
        public var linePairAsymmetry = 0.0
        public var bobFlutter = 0.0
        public var flicker = 0.0
        /// Beat on which frames come out softer than their neighbours.
        /// Measured on synthetic clips this is the current encoder's own
        /// rhythm (its B-frames are a little softer than its P-frames, on
        /// a beat of four with x264's defaults), so it is recorded as a
        /// property of the encode and not read as a sign of blending.
        public var sharpnessPeriod: Int?
        public var sharpnessPeriodStrength = 0.0
    }

    public func reading() -> Reading {
        var reading = Reading()
        reading.cadence = CadenceReading.read(differences)
        if !blendedFlags.isEmpty {
            reading.blendedFraction = Double(blendedFlags.count { $0 }) / Double(blendedFlags.count)
        }

        let judged = combedShares.filter { $0 > 0 }
        reading.combedShareTypical = FrameSummary.percentile(judged, 0.5) ?? 0
        reading.combedShareHigh = FrameSummary.percentile(judged, 0.9) ?? 0
        let combed = combedShares.map { $0 >= Self.combedFrameShare }
        if !judged.isEmpty {
            reading.combedFrameFraction = Double(combed.count { $0 }) / Double(combedShares.count)
        }
        // Some combed, some not, on a beat: fields from a film cadence.
        if reading.combedFrameFraction > 0.15, reading.combedFrameFraction < 0.85 {
            reading.combedPeriod = CadenceReading.beat(in: combed.map { $0 ? 1.0 : 0.0 })?.period
        }

        reading.linePairAsymmetry = FrameSummary.percentile(linePairAsymmetries, 0.5) ?? 0
        reading.bobFlutter = -(FrameSummary.percentile(changeCorrelations, 0.5) ?? 0)
        if let beat = CadenceReading.beat(in: gradientEnergies) {
            reading.sharpnessPeriod = beat.period
            reading.sharpnessPeriodStrength = beat.strength
        }

        // Brightness that jumps frame to frame, against its own slow drift.
        if meanLevels.count >= 8 {
            let residuals = meanLevels.indices.map { index -> Double in
                let nearby = meanLevels[max(index - 2, 0)...min(index + 2, meanLevels.count - 1)]
                return meanLevels[index] - nearby.reduce(0, +) / Double(nearby.count)
            }
            let variance = residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)
            reading.flicker = variance.squareRoot()
        }
        return reading
    }
}
