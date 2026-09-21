import Foundation
import Testing
@testable import SightsAndSoundsKit

@Suite struct ColourReadingTests {
    private let whole = PictureGeometry.ActiveArea(left: 0, top: 0, width: 128, height: 96)

    /// Frames whose luma ramps from `low` to `high`, with given chroma.
    private func frames(
        low: Float, high: Float, cb: Float = 128, cr: Float = 128, bitDepth: Int = 8, step: Float = 1
    ) -> [PictureFrame] {
        (0..<4).map { index in
            let luma = (0..<128 * 96).map { pixel -> Float in
                let value = low + (high - low) * Float(pixel % 128) / 127
                return (value / step).rounded() * step
            }
            return PictureFrame(
                width: 128, height: 96, luma: luma, chromaWidth: 64, chromaHeight: 48,
                cb: [Float](repeating: cb, count: 64 * 48), cr: [Float](repeating: cr, count: 64 * 48),
                positionSeconds: Double(index), bitDepth: bitDepth)
        }
    }

    @Test func videoRangePictureIsReadAsVideoRange() {
        let findings = ColourReading.measure(frames(low: 16, high: 235), in: whole)
        #expect(findings.value("colour.usesFullRange") == 0)
        #expect(findings.value("colour.washedOut") == 0)
        #expect(abs(findings.value("colour.lumaLowest")! - 16) < 2)
        // Every other column is sampled, so the last one seen is 126 of 127.
        #expect(abs(findings.value("colour.lumaHighest")! - 235) < 3)
        #expect(findings.value("colour.belowVideoBlackShare")! == 0)
    }

    @Test func aPictureReachingZeroAndTwoFiftyFiveIsFullRange() {
        let findings = ColourReading.measure(frames(low: 0, high: 255), in: whole)
        #expect(findings.value("colour.usesFullRange") == 1)
        #expect(findings.value("colour.belowVideoBlackShare")! > 0.04)
        #expect(findings.value("colour.aboveVideoWhiteShare")! > 0.04)
    }

    @Test func aPictureThatNeverNearsBlackOrWhiteIsWashedOut() {
        #expect(ColourReading.measure(frames(low: 45, high: 200), in: whole).value("colour.washedOut") == 1)
    }

    @Test func neutralChromaIsMonochromeAndColourIsNot() {
        #expect(ColourReading.measure(frames(low: 16, high: 235), in: whole).value("colour.monochrome") == 1)
        let coloured = ColourReading.measure(frames(low: 16, high: 235, cb: 100, cr: 160), in: whole)
        #expect(coloured.value("colour.monochrome") == 0)
        #expect(abs(coloured.value("colour.saturation", .median)! - 42.5) < 0.1)
    }

    @Test func eightBitContentInATenBitFileLeavesTheLowBitsUnused() {
        let padded = ColourReading.measure(frames(low: 16, high: 235, bitDepth: 10, step: 1), in: whole)
        #expect(padded.value("colour.lowBitsUsedShare")! < 0.01)
        let real = ColourReading.measure(frames(low: 16, high: 235, bitDepth: 10, step: 0.25), in: whole)
        #expect(real.value("colour.lowBitsUsedShare")! > 0.5)
        // Not a question for an 8-bit file.
        #expect(ColourReading.measure(frames(low: 16, high: 235), in: whole).value("colour.lowBitsUsedShare") == nil)
    }
}

@Suite struct ChromaReadingTests {
    private let whole = PictureGeometry.ActiveArea(left: 0, top: 0, width: 640, height: 360)

    private func frame(chroma: PictureFrame, luma: PictureFrame? = nil) -> PictureFrame {
        let luma = luma ?? SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 640, sourceHeight: 360)
        return PictureFrame(
            width: 640, height: 360, luma: luma.luma, chromaWidth: 320, chromaHeight: 180,
            cb: chroma.luma, cr: chroma.luma)
    }

    @Test func colourWithAQuarterOfItsDetailAcrossIsTheShapeTapeLeaves() {
        let narrow = SyntheticPicture.upscaledNoise(width: 320, height: 180, sourceWidth: 40, sourceHeight: 180)
        let findings = ChromaReading.measure([frame(chroma: narrow)], in: whole)
        #expect(findings.value("chroma.horizontalFill", .high)! < 0.12)
        #expect(findings.value("chroma.verticalFill", .high)! > 0.4)
        #expect(findings.value("chroma.horizontalToVerticalFill")! < 0.25)
    }

    @Test func fullDetailColourFillsItsPlanes() {
        let full = SyntheticPicture.upscaledNoise(width: 320, height: 180, sourceWidth: 320, sourceHeight: 180)
        let findings = ChromaReading.measure([frame(chroma: full)], in: whole)
        #expect(findings.value("chroma.horizontalFill", .high)! > 0.4)
        #expect(findings.value("chroma.horizontalToVerticalFill")! > 0.8)
        #expect(findings.value("chroma.noiseLimitedShare") == 0)
    }

    @Test func colourEdgesSittingToTheRightOfTheirLumaEdgesAreMeasured() {
        // Vertical bars in luma; the same bars in chroma, two samples late.
        func bars(width: Int, height: Int, period: Int, shift: Int) -> PictureFrame {
            SyntheticPicture.frame(width: width, height: height) { x, _ in
                ((x - shift + period * 8) / period).isMultiple(of: 2) ? 180 : 70
            }
        }
        let luma = bars(width: 640, height: 360, period: 46, shift: 0)
        let late = frame(chroma: bars(width: 320, height: 180, period: 23, shift: 2), luma: luma)
        let aligned = frame(chroma: bars(width: 320, height: 180, period: 23, shift: 0), luma: luma)
        #expect(abs(ChromaReading.horizontalOffset(late, in: .init(left: 0, top: 0, width: 319, height: 179))! - 2) < 0.3)
        #expect(abs(ChromaReading.horizontalOffset(aligned, in: .init(left: 0, top: 0, width: 319, height: 179))!) < 0.3)
    }
}

@Suite struct NoiseReadingTests {
    private let whole = PictureGeometry.ActiveArea(left: 0, top: 0, width: 320, height: 192)

    /// A flat frame at `level` with `noise(x, y)` added.
    private func noisy(level: (Int, Int) -> Float, noise: (Int, Int) -> Float) -> PictureFrame {
        SyntheticPicture.frame(width: 320, height: 192) { x, y in level(x, y) + noise(x, y) }
    }

    private func field(amplitude: Float) -> [Float] {
        var generator = SyntheticPicture.Noise()
        return (0..<320 * 192).map { _ in generator.signedUnit() * amplitude }
    }

    @Test func whiteNoiseOfKnownSizeIsMeasuredAndHasNoGrain() {
        let values = field(amplitude: 6)  // sigma 6 / sqrt(3) = 3.46
        let findings = NoiseReading.measure([noisy(level: { _, _ in 120 }) { x, y in values[y * 320 + x] }], in: whole)
        // The flattest tenth of blocks reads a little under the true figure.
        #expect(abs(findings.value("noise.sigma", .median)! - 3.46) < 0.5)
        #expect(abs(findings.value("noise.horizontalCorrelation")!) < 0.1)
        #expect(abs(findings.value("noise.verticalCorrelation")!) < 0.1)
    }

    @Test func noiseSmearedAlongTheLinesIsAnisotropic() {
        let values = field(amplitude: 12)
        let frame = noisy(level: { _, _ in 120 }) { x, y in
            (0..<4).reduce(Float(0)) { $0 + values[y * 320 + min(x + $1, 319)] } / 2
        }
        let findings = NoiseReading.measure([frame], in: whole)
        #expect(findings.value("noise.horizontalCorrelation")! > 0.5)
        #expect(abs(findings.value("noise.verticalCorrelation")!) < 0.15)
        #expect(findings.value("noise.anisotropy")! > 0.4)
    }

    @Test func noiseScaledUpWithThePictureCorrelatesBothWays() {
        let values = field(amplitude: 12)
        let frame = noisy(level: { _, _ in 120 }) { x, y in values[(y / 2) * 320 + x / 2] }
        let findings = NoiseReading.measure([frame], in: whole)
        #expect(findings.value("noise.horizontalCorrelation")! > 0.35)
        #expect(findings.value("noise.verticalCorrelation")! > 0.35)
    }

    @Test func grainHeavierInTheMidtonesThanTheShadowsIsReported() {
        let values = field(amplitude: 1)
        let frame = noisy(level: { x, _ in x < 160 ? 45 : 120 }) { x, y in
            values[y * 320 + x] * (x < 160 ? 2 : 8)
        }
        let findings = NoiseReading.measure([frame, frame, frame], in: whole)
        #expect(abs(findings.value("noise.midtoneToShadowRatio")! - 4) < 0.6)
    }

    @Test func aSmoothGradientIsNotNoise() {
        let frame = noisy(level: { x, y in 60 + Float(x) * 0.4 + Float(y) * 0.2 }) { _, _ in 0 }
        #expect(NoiseReading.measure([frame], in: whole).value("noise.sigma", .median)! < 0.05)
    }

    @Test func clippedBlocksAreLeftOut() {
        let frame = noisy(level: { _, _ in 8 }) { _, _ in 0 }
        #expect(NoiseReading.measure([frame], in: whole).measured.isEmpty)
    }
}
