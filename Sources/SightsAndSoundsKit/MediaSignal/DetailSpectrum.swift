import Accelerate
import Foundation

/// How much real detail a frame holds, as opposed to how many pixels it
/// was encoded with.
///
/// Scaling a picture up adds pixels and no information: the spectrum of an
/// upscaled frame stops where the original's did. The luma power spectrum
/// is averaged over many rows (and, separately, many columns) and read two
/// ways, because each is fooled by something the other is not:
///
/// - the frequency enclosing 99.9 % of the energy. Right for ordinary
///   pictures, whose spectra fall steeply; a cheap scaler's faint leakage
///   on noisy, flat-spectrum content pushes it far too high.
/// - the first place the spectrum steps down by more than its own trend
///   explains. Right for that noisy content; blind on a steep spectrum,
///   where there is no step left to see.
///
/// The effective size is the smaller of the two. Measured on synthetic
/// material, a pristine 1080p photograph read about 1000 of 1920 pixels,
/// and the same picture taken through SD and scaled back up read 360 to
/// 490, so the number is a property of the content as well as the source:
/// it is taken over many frames, the high percentile is what is compared,
/// and it is reported as "detail consistent with about N pixels", never
/// as the source's size. All three readings are stored, so the thresholds
/// can be settled against files whose history is known.
public enum DetailSpectrum {
    /// The share of AC energy the cutoff encloses.
    static let enclosedEnergy: Float = 0.999

    public struct Cutoff: Equatable, Sendable {
        /// Fraction of Nyquist, 0...1, below which `enclosedEnergy` sits.
        public var fraction: Double
        /// The same for 99 % of the energy: where the bulk of the detail is.
        public var bulkFraction: Double
        /// Where the spectrum falls off a cliff, or 1 when it never does.
        public var cliffFraction: Double
    }

    /// How far below its own low-frequency trend the spectrum has to fall,
    /// and stay, to count as having stopped.
    static let cliffDepthDecibels: Float = 8

    /// Horizontal detail: spectra of rows inside `area`.
    public static func horizontal(_ frame: PictureFrame, in area: PictureGeometry.ActiveArea) -> Cutoff? {
        cutoff(length: area.width, lines: area.height) { line, offset, count, into in
            let start = (area.top + line) * frame.width + area.left + offset
            frame.luma.withUnsafeBufferPointer { plane in
                into.update(from: plane.baseAddress! + start, count: count)
            }
        }
    }

    /// Vertical detail: spectra of columns inside `area`.
    public static func vertical(_ frame: PictureFrame, in area: PictureGeometry.ActiveArea) -> Cutoff? {
        cutoff(length: area.height, lines: area.width) { line, offset, count, into in
            let column = area.left + line
            for index in 0..<count {
                into[index] = frame.luma[(area.top + offset + index) * frame.width + column]
            }
        }
    }

    /// Average the power spectra of up to ~128 evenly spaced lines, each
    /// `length` samples long, and find the cutoffs. `fill` copies one
    /// line's centred window into the buffer it is given.
    static func cutoff(
        length: Int, lines: Int,
        fill: (_ line: Int, _ offset: Int, _ count: Int, _ into: UnsafeMutablePointer<Float>) -> Void
    ) -> Cutoff? {
        guard length >= 64, lines >= 8 else { return nil }
        let log2n = vDSP_Length(floor(log2(Double(min(length, 4096)))))
        let n = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Float](repeating: 0, count: n / 2)
        var samples = [Float](repeating: 0, count: n)
        var imaginary = [Float](repeating: 0, count: n)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        let offset = (length - n) / 2

        // The outer eighth at each end is where overscan junk and soft
        // vignetting live; the middle is the picture.
        let firstLine = lines / 8, lastLine = lines - lines / 8
        let step = max((lastLine - firstLine) / 128, 1)
        for line in stride(from: firstLine, to: lastLine, by: step) {
            samples.withUnsafeMutableBufferPointer { fill(line, offset, n, $0.baseAddress!) }
            var mean: Float = 0
            vDSP_meanv(samples, 1, &mean, vDSP_Length(n))
            mean = -mean
            vDSP_vsadd(samples, 1, &mean, &samples, 1, vDSP_Length(n))
            vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))
            vDSP_vclr(&imaginary, 1, vDSP_Length(n))
            samples.withUnsafeMutableBufferPointer { real in
                imaginary.withUnsafeMutableBufferPointer { imag in
                    var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_vadd(power, 1, magnitudes, 1, &power, 1, vDSP_Length(n / 2))
        }
        return cutoff(ofPower: power)
    }

    static func cutoff(ofPower power: [Float]) -> Cutoff? {
        let total = power.dropFirst().reduce(0, +)
        // A flat frame has no spectrum to read a cutoff from.
        guard total > 0, power.count > 8 else { return nil }
        var running: Float = 0
        var bulk: Int?
        var edge = power.count - 1
        for bin in 1..<power.count {
            running += power[bin]
            if bulk == nil, running >= total * 0.99 { bulk = bin }
            if running >= total * enclosedEnergy {
                edge = bin
                break
            }
        }
        let nyquist = Double(power.count)
        return Cutoff(
            fraction: Double(edge) / nyquist, bulkFraction: Double(bulk ?? edge) / nyquist,
            cliffFraction: Double(cliff(inPower: power)) / nyquist)
    }

    /// The bin at which the spectrum drops away from its own trend.
    ///
    /// The energy cutoffs above answer "where is most of the detail", and
    /// a cheap scaler fools them: linear interpolation leaks faint images
    /// of the spectrum far past the source's limit, and a thousandth of
    /// the energy is easily found out there. What scaling cannot fake is
    /// the shape. A picture's spectrum follows a power law, and one that
    /// was scaled up follows it to the source's limit and then falls well
    /// below it. So the trend is fitted over the lowest tenth of the band,
    /// where any plausible source still has detail, and the cliff is the
    /// first bin after which the spectrum stays `cliffDepthDecibels` under
    /// that trend all the way out.
    static func cliff(inPower power: [Float]) -> Int {
        let count = power.count
        guard count >= 64 else { return count }
        // Decibels, smoothed over about 2 % of the band each way.
        let decibels = power.map { 10 * log10(max($0, 1e-12)) }
        let reach = max(count / 50, 2)
        let smoothed = (0..<count).map { bin -> Float in
            let range = max(bin - reach, 1)...min(bin + reach, count - 1)
            return decibels[range].reduce(0, +) / Float(range.count)
        }

        // Least squares of level against log-frequency.
        let fitted = max(count / 100, 2)...max(count / 10, 8)
        let xs = fitted.map { log10(Float($0)) }, ys = fitted.map { smoothed[$0] }
        let meanX = xs.reduce(0, +) / Float(xs.count), meanY = ys.reduce(0, +) / Float(ys.count)
        let spread = zip(xs, ys).reduce(Float(0)) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard spread > 0 else { return count }
        // A spectrum never rises with frequency; a fit that says so has
        // met noise, and a flat trend is the safe reading of it.
        let slope = min(zip(xs, ys).reduce(Float(0)) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / spread, 0)

        // Compare the level just below each frequency with the level just
        // above it, and take away the fall the trend itself accounts for.
        // What is left is the step a scaler's cutoff put there.
        func level(_ from: Double, _ to: Double) -> Float? {
            let range = max(Int(from), 1)...min(Int(to), count - 1)
            guard range.lowerBound < range.upperBound else { return nil }
            return smoothed[range].reduce(0, +) / Float(range.count)
        }
        let expected = -slope * log10(Float(1.25 * 1.25))
        // The first step deep enough, then the deepest point of that same
        // step: later ones are the scaler's sidelobes, not the source.
        var cliff = count
        var deepest: Float = 0
        for bin in fitted.upperBound..<Int(Double(count) * 0.9) {
            if cliff != count, Double(bin) > Double(cliff) * 1.3 { break }
            let centre = Double(bin)
            guard let below = level(centre / 1.4, centre / 1.1), let above = level(centre * 1.1, centre * 1.4)
            else { continue }
            let step = below - above - expected
            if step > max(deepest, cliffDepthDecibels) {
                deepest = step
                cliff = bin
            }
        }
        return cliff
    }

    /// Per-frame cutoffs and their summaries, in pixels of the active area.
    public static func measure(_ frames: [PictureFrame], in area: PictureGeometry.ActiveArea) -> SignalFindings {
        var findings = SignalFindings()
        var across: [(Double, Double)] = [], down: [(Double, Double)] = []
        var acrossBulk: [(Double, Double)] = [], downBulk: [(Double, Double)] = []
        var acrossCliff: [(Double, Double)] = [], downCliff: [(Double, Double)] = []
        for frame in frames {
            if let cutoff = horizontal(frame, in: area) {
                across.append((frame.positionSeconds, cutoff.fraction * Double(area.width)))
                acrossBulk.append((frame.positionSeconds, cutoff.bulkFraction * Double(area.width)))
                acrossCliff.append((frame.positionSeconds, cutoff.cliffFraction * Double(area.width)))
            }
            if let cutoff = vertical(frame, in: area) {
                down.append((frame.positionSeconds, cutoff.fraction * Double(area.height)))
                downBulk.append((frame.positionSeconds, cutoff.bulkFraction * Double(area.height)))
                downCliff.append((frame.positionSeconds, cutoff.cliffFraction * Double(area.height)))
            }
        }
        let effectiveAcross = zip(across, acrossCliff).map { ($0.0, min($0.1, $1.1)) }
        let effectiveDown = zip(down, downCliff).map { ($0.0, min($0.1, $1.1)) }
        FrameSummary.record("detail.effectiveWidth", effectiveAcross, into: &findings)
        FrameSummary.record("detail.effectiveHeight", effectiveDown, into: &findings)
        FrameSummary.record("detail.energyWidth", across, into: &findings)
        FrameSummary.record("detail.energyHeight", down, into: &findings)
        FrameSummary.record("detail.bulkWidth", acrossBulk, into: &findings)
        FrameSummary.record("detail.bulkHeight", downBulk, into: &findings)
        FrameSummary.record("detail.cliffWidth", acrossCliff, into: &findings)
        FrameSummary.record("detail.cliffHeight", downCliff, into: &findings)

        // The best the file shows, against the size it was encoded at.
        if let best = FrameSummary.percentile(effectiveAcross.map(\.1), 0.9), best > 0 {
            findings.measure("detail.horizontalFill", best / Double(area.width))
        }
        if let best = FrameSummary.percentile(effectiveDown.map(\.1), 0.9), best > 0 {
            findings.measure("detail.verticalFill", best / Double(area.height))
        }
        // Tape is far softer across than down; a field-based deinterlace
        // is the other way about.
        if let wide = FrameSummary.percentile(effectiveAcross.map(\.1), 0.9),
           let tall = FrameSummary.percentile(effectiveDown.map(\.1), 0.9), tall > 0, wide > 0 {
            findings.measure(
                "detail.horizontalToVerticalFill",
                (wide / Double(area.width)) / (tall / Double(area.height)))
        }
        return findings
    }
}
