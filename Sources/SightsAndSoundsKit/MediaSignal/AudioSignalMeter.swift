import Accelerate
import Foundation

/// Measures a sound track as it streams past: level and loudness, the
/// long-term spectrum, how alike the two channels are, and what is left
/// in the quietest passages.
///
/// Sound keeps its history better than picture does. A re-encode to AAC at
/// a generous bitrate leaves a tape's 10 kHz bandwidth, its hiss, the mains
/// hum of the machine that played it and the 15.7 kHz whistle of the
/// monitor beside it exactly where they were, so several of these are among
/// the most reliable signs of origin the job has.
///
/// Samples arrive in whatever pieces the decoder produces. Nothing is kept
/// but running sums, one averaged spectrum, a short list of quiet blocks
/// and a loudness value per tenth of a second, so a three-hour file costs
/// no more memory than a three-minute one.
public final class AudioSignalMeter {
    /// 16 384 points is 2.9 Hz a bin at 48 kHz: enough to tell 50 Hz hum
    /// from 60 Hz, and a line whistle from the music around it.
    static let spectrumLength = 16_384
    static let quietBlocksKept = 48
    /// Below this a block is digital silence, which has no noise floor.
    static let silenceMeanSquare = 1e-10

    let sampleRate: Double
    let channels: Int

    private var frames = 0
    private var peak: Float = 0
    private var sumSquares = [Double](repeating: 0, count: 2)
    private var sumProduct = 0.0
    private var sumSideSquares = 0.0
    private var sumMidSquares = 0.0

    private var clippedRuns = 0
    private var clippedSamples = 0
    private var currentRun = [0, 0]

    // Long-term spectrum of the mid channel.
    private var pending: [Float] = []
    private var power: [Float]
    private var spectra = 0
    private var quiet: [(meanSquare: Double, power: [Float])] = []
    private let fft: FFTSetup
    private let window: [Float]

    // Loudness: K-weighted energy per tenth of a second.
    private var weighting: [vDSP.Biquad<Double>]
    private let chunkLength: Int
    private var chunkFill = 0
    private var chunkEnergy = 0.0
    private var chunkEnergies: [Double] = []

    public init?(sampleRate: Double, channels: Int) {
        guard sampleRate >= 8000, (1...2).contains(channels),
              let fft = vDSP_create_fftsetup(14, FFTRadix(kFFTRadix2))
        else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: Self.spectrumLength, isHalfWindow: false)
        power = [Float](repeating: 0, count: Self.spectrumLength / 2)
        chunkLength = Int((sampleRate / 10).rounded())
        let coefficients = Self.kWeighting(sampleRate: sampleRate)
        weighting = (0..<channels).compactMap { _ in
            vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Double.self)
        }
        guard weighting.count == channels else { return nil }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// The two filters of ITU-R BS.1770, derived for any sample rate: a
    /// high shelf for the head's effect, then a high-pass.
    static func kWeighting(sampleRate: Double) -> [Double] {
        var k = tan(.pi * 1681.974450955533 / sampleRate)
        let q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [
            (vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0,
        ]
        k = tan(.pi * 38.13547087602444 / sampleRate)
        let highQ = 0.5003270373238773
        a0 = 1 + k / highQ + k * k
        let highPass = [1.0, -2.0, 1.0, 2 * (k * k - 1) / a0, (1 - k / highQ + k * k) / a0]
        return shelf + highPass
    }

    // MARK: - Consuming

    /// One piece of the track. `right` is nil for a mono track.
    public func consume(left: [Float], right: [Float]?) {
        let count = left.count
        guard count > 0 else { return }
        frames += count
        let both: [[Float]] = right.map { [left, $0] } ?? [left]

        for (index, channel) in both.enumerated() {
            peak = max(peak, vDSP.maximumMagnitude(channel))
            sumSquares[index] += Double(vDSP.sumOfSquares(channel))
            countClipping(channel, channel: index)
        }

        let mid: [Float]
        if let right {
            sumProduct += Double(vDSP.dot(left, right))
            mid = vDSP.multiply(0.5, vDSP.add(left, right))
            let side = vDSP.multiply(0.5, vDSP.subtract(left, right))
            sumSideSquares += Double(vDSP.sumOfSquares(side))
        } else {
            mid = left
        }
        sumMidSquares += Double(vDSP.sumOfSquares(mid))

        accumulateSpectrum(mid)
        accumulateLoudness(both)
    }

    /// A run of three or more samples at full scale is a flattened peak;
    /// one alone is just a loud sample.
    private func countClipping(_ samples: [Float], channel: Int) {
        var run = currentRun[channel]
        for sample in samples {
            if abs(sample) >= 0.999 {
                run += 1
                if run == 3 {
                    clippedRuns += 1
                    clippedSamples += 3
                } else if run > 3 {
                    clippedSamples += 1
                }
            } else {
                run = 0
            }
        }
        currentRun[channel] = run
    }

    private func accumulateSpectrum(_ mid: [Float]) {
        pending += mid
        let length = Self.spectrumLength
        var offset = 0
        var real = [Float](repeating: 0, count: length)
        var imaginary = [Float](repeating: 0, count: length)
        var magnitudes = [Float](repeating: 0, count: length / 2)
        while pending.count - offset >= length {
            let block = Array(pending[offset..<offset + length])
            offset += length
            let meanSquare = Double(vDSP.meanSquare(block))
            vDSP.multiply(block, window, result: &real)
            vDSP.fill(&imaginary, with: 0)
            real.withUnsafeMutableBufferPointer { realPart in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                    var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                    vDSP_fft_zip(fft, &split, 1, 14, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(length / 2))
                }
            }
            vDSP.add(power, magnitudes, result: &power)
            spectra += 1
            keepIfQuiet(meanSquare: meanSquare, power: magnitudes)
        }
        pending.removeFirst(offset)
    }

    private func keepIfQuiet(meanSquare: Double, power: [Float]) {
        guard meanSquare > Self.silenceMeanSquare else { return }
        if quiet.count < Self.quietBlocksKept {
            quiet.append((meanSquare, power))
        } else if let loudest = quiet.indices.max(by: { quiet[$0].meanSquare < quiet[$1].meanSquare }),
                  quiet[loudest].meanSquare > meanSquare {
            quiet[loudest] = (meanSquare, power)
        }
    }

    private func accumulateLoudness(_ both: [[Float]]) {
        let weighted = both.enumerated().map { index, channel in
            weighting[index].apply(input: vDSP.floatToDouble(channel))
        }
        let count = both[0].count
        var offset = 0
        while offset < count {
            let take = min(chunkLength - chunkFill, count - offset)
            for channel in weighted {
                chunkEnergy += vDSP.sumOfSquares(channel[offset..<offset + take])
            }
            chunkFill += take
            offset += take
            if chunkFill == chunkLength {
                chunkEnergies.append(chunkEnergy / Double(chunkLength))
                chunkFill = 0
                chunkEnergy = 0
            }
        }
    }

    // MARK: - Reporting

    static func decibels(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-20)) }

    public func findings() -> SignalFindings {
        var findings = SignalFindings()
        guard frames > 0 else { return findings }
        findings.measure("audio.secondsMeasured", Double(frames) / sampleRate)

        let meanSquare = sumSquares.prefix(channels).reduce(0, +) / Double(frames * channels)
        let peakDecibels = 20 * log10(Double(max(peak, 1e-10)))
        findings.measure("audio.peakDb", peakDecibels)
        findings.measure("audio.rmsDb", Self.decibels(meanSquare))
        findings.measure("audio.crestFactorDb", peakDecibels - Self.decibels(meanSquare))
        findings.measure("audio.clippedRuns", Double(clippedRuns))
        findings.measure("audio.clippedFraction", Double(clippedSamples) / Double(frames * channels))

        if channels == 2 {
            let energy = (sumSquares[0] * sumSquares[1]).squareRoot()
            if energy > 0 { findings.measure("audio.channelCorrelation", sumProduct / energy) }
            // How much of the sound is difference between the channels.
            // Two copies of one channel have none at all.
            if sumMidSquares > 0 {
                findings.measure("audio.sideToMidDb", Self.decibels(sumSideSquares / sumMidSquares))
            }
            findings.measure("audio.monoAsStereo", sumSideSquares <= sumMidSquares * 1e-6 ? 1 : 0)
        }

        measureLoudness(into: &findings)
        if spectra > 0 {
            AudioSpectrumReading.measure(
                power: power.map { $0 / Float(spectra) }, sampleRate: sampleRate, prefix: "audio",
                into: &findings)
        }
        if quiet.count >= 4 {
            var floor = [Float](repeating: 0, count: Self.spectrumLength / 2)
            for block in quiet { vDSP.add(floor, block.power, result: &floor) }
            let level = quiet.map(\.meanSquare).reduce(0, +) / Double(quiet.count)
            findings.measure("audio.noiseFloorDb", Self.decibels(level))
            AudioSpectrumReading.measureHum(
                power: floor.map { $0 / Float(quiet.count) }, sampleRate: sampleRate, into: &findings)
        }
        return findings
    }

    /// Integrated loudness and loudness range, gated as EBU R 128 says:
    /// 400 ms blocks (3 s for the range) stepped a tenth of a second at a
    /// time, an absolute gate at -70, then a gate relative to what is left.
    private func measureLoudness(into findings: inout SignalFindings) {
        func blocks(of length: Int, step: Int) -> [Double] {
            guard chunkEnergies.count >= length else { return [] }
            return stride(from: 0, through: chunkEnergies.count - length, by: step).map { start in
                chunkEnergies[start..<start + length].reduce(0, +) / Double(length)
            }
        }
        func loudness(_ energy: Double) -> Double { -0.691 + Self.decibels(energy) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

        let momentary = blocks(of: 4, step: 1).filter { loudness($0) > -70 }
        guard !momentary.isEmpty else { return }
        let relative = loudness(mean(momentary)) - 10
        let gated = momentary.filter { loudness($0) > relative }
        if !gated.isEmpty { findings.measure("audio.integratedLoudnessLufs", loudness(mean(gated))) }

        let shortTerm = blocks(of: 30, step: 10).filter { loudness($0) > -70 }
        guard !shortTerm.isEmpty else { return }
        let rangeGate = loudness(mean(shortTerm)) - 20
        let levels = shortTerm.map(loudness).filter { $0 > rangeGate }
        if let low = FrameSummary.percentile(levels, 0.10), let high = FrameSummary.percentile(levels, 0.95) {
            findings.measure("audio.loudnessRangeLu", high - low)
        }
    }
}
