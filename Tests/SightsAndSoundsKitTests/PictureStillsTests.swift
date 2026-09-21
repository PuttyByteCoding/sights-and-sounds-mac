import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Synthetic frames with known contents, so every expectation below is
/// arithmetic rather than a reading taken from some file.
enum SyntheticPicture {
    /// Deterministic noise in 40...220, so tests never depend on a seed.
    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 40 + Float(state >> 40 & 0xFF) / 255 * 180
        }

        /// Uniform in -1...1.
        mutating func signedUnit() -> Float { (next() - 130) / 90 }
    }

    /// A `width` x `height` frame, black (code 16) outside `area`, with
    /// `texture(x, y)` inside it.
    static func frame(
        width: Int, height: Int, area: PictureGeometry.ActiveArea? = nil, at seconds: Double = 0,
        texture: (Int, Int) -> Float
    ) -> PictureFrame {
        let area = area ?? .init(left: 0, top: 0, width: width, height: height)
        var luma = [Float](repeating: 16, count: width * height)
        for y in area.top..<area.top + area.height {
            for x in area.left..<area.left + area.width {
                luma[y * width + x] = texture(x - area.left, y - area.top)
            }
        }
        return PictureFrame(width: width, height: height, luma: luma, positionSeconds: seconds)
    }

    /// A texture with a picture's kind of spectrum, falling away with
    /// frequency but present right up to the limit: noise at every scale
    /// from one pixel up, the coarse scales the strongest.
    static func texture(width: Int, height: Int) -> [Float] {
        var noise = Noise()
        var out = [Float](repeating: 128, count: width * height)
        var scale = 1
        while scale <= 32 {
            let columns = width / scale + 2, rows = height / scale + 2
            let layer = (0..<columns * rows).map { _ in noise.signedUnit() }
            let weight = pow(Float(scale), 1.5) * 0.35
            for y in 0..<height {
                for x in 0..<width { out[y * width + x] += layer[(y / scale) * columns + x / scale] * weight }
            }
            scale *= 2
        }
        // A lens and a sensor soften what they sample. Hard-edged blocks
        // alias, which levels the top of the spectrum the way noise does,
        // and no camera picture looks like that.
        func softened(_ plane: [Float], step: Int, limit: Int) -> [Float] {
            plane.indices.map { index in
                let position = step == 1 ? index % width : index / width
                let before = position > 0 ? plane[index - step] : plane[index]
                let after = position < limit - 1 ? plane[index + step] : plane[index]
                return (before + 2 * plane[index] + after) / 4
            }
        }
        return softened(softened(out, step: 1, limit: width), step: width, limit: height)
    }

    /// A `texture` made at `sourceWidth` x `sourceHeight` and scaled up to
    /// `width` x `height` by linear interpolation: a picture with the
    /// pixel count of one size and the detail of another.
    static func upscaledNoise(width: Int, height: Int, sourceWidth: Int, sourceHeight: Int) -> PictureFrame {
        let source = texture(width: sourceWidth, height: sourceHeight)
        func at(_ x: Int, _ y: Int) -> Float {
            source[min(y, sourceHeight - 1) * sourceWidth + min(x, sourceWidth - 1)]
        }
        return frame(width: width, height: height) { x, y in
            let sx = Float(x) * Float(sourceWidth) / Float(width)
            let sy = Float(y) * Float(sourceHeight) / Float(height)
            let x0 = Int(sx), y0 = Int(sy)
            let fx = sx - Float(x0), fy = sy - Float(y0)
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }
}

@Suite struct PictureGeometryTests {
    private let pillarbox = PictureGeometry.ActiveArea(left: 80, top: 0, width: 480, height: 360)

    private func textured(_ area: PictureGeometry.ActiveArea?, count: Int = 10) -> [PictureFrame] {
        var noise = SyntheticPicture.Noise()
        return (0..<count).map { index in
            SyntheticPicture.frame(width: 640, height: 360, area: area, at: Double(index)) { _, _ in noise.next() }
        }
    }

    @Test func aFourByThreePictureInsideASixteenByNineFrameIsFound() {
        let findings = PictureGeometry.measure(textured(pillarbox))
        #expect(findings.value("geometry.activeLeft") == 80)
        #expect(findings.value("geometry.activeWidth") == 480)
        #expect(findings.value("geometry.activeHeight") == 360)
        #expect(findings.value("geometry.pillarboxed") == 1)
        #expect(findings.value("geometry.letterboxed") == 0)
        #expect(abs(findings.value("geometry.activeAspectRatio")! - 4.0 / 3) < 1e-9)
        #expect(findings.value("geometry.standardAspectRatio") == 4.0 / 3)
        // Painted bars: one flat value, and an edge with nothing in between.
        #expect(findings.value("geometry.borderNoise")! < 0.01)
        #expect(findings.value("geometry.borderEdgeWidth") == 0)
    }

    @Test func aFullFramePictureHasNoBars() {
        let findings = PictureGeometry.measure(textured(nil))
        #expect(findings.value("geometry.activeWidth") == 640)
        #expect(findings.value("geometry.pillarboxed") == 0)
        #expect(findings.value("geometry.borderNoise") == nil)
    }

    @Test func darkFramesAndASubtitleInTheBarDoNotMoveTheBounds() {
        let letterbox = PictureGeometry.ActiveArea(left: 0, top: 44, width: 640, height: 272)
        var frames = textured(letterbox, count: 12)
        // Two frames that are black, and two dark but for their middle.
        frames.append(SyntheticPicture.frame(width: 640, height: 360) { _, _ in 16 })
        frames.append(SyntheticPicture.frame(width: 640, height: 360) { _, _ in 17 })
        let middle = PictureGeometry.ActiveArea(left: 200, top: 150, width: 200, height: 60)
        frames.append(SyntheticPicture.frame(width: 640, height: 360, area: middle) { _, _ in 120 })
        frames.append(SyntheticPicture.frame(width: 640, height: 360, area: middle) { _, _ in 130 })
        // One frame with a bright subtitle inside the lower bar.
        var subtitled = frames[0].luma
        for y in 332..<346 { for x in 100..<540 { subtitled[y * 640 + x] = 235 } }
        frames.append(PictureFrame(width: 640, height: 360, luma: subtitled))

        let findings = PictureGeometry.measure(frames)
        #expect(findings.value("geometry.activeTop") == 44)
        #expect(findings.value("geometry.activeHeight") == 272)
        #expect(findings.value("geometry.letterboxed") == 1)
        #expect(abs(findings.value("geometry.activeAspectRatio")! - 2.353) < 0.001)
        #expect(findings.value("geometry.standardAspectRatio") == 2.35)
    }

    @Test func anamorphicPixelsChangeTheShapeNotTheBounds() {
        let findings = PictureGeometry.measure(textured(nil), pixelAspectRatio: 32.0 / 27)
        #expect(findings.value("geometry.activeWidth") == 640)
        #expect(abs(findings.value("geometry.encodedAspectRatio")! - 640.0 * 32 / 27 / 360) < 1e-9)
    }

    @Test func barsThatWereScaledWithThePictureHaveASoftNoisyEdge() {
        var noise = SyntheticPicture.Noise()
        let frames = (0..<10).map { _ in
            SyntheticPicture.frame(width: 640, height: 360) { x, _ in
                // A six-pixel ramp either side, and bars that carry noise.
                let inside = min(x - 80, 559 - x)
                let picture: Float = 150
                let bar = 16 + (noise.next() - 130) / 30
                if inside >= 6 { return picture }
                if inside < 0 { return bar }
                return bar + (picture - bar) * Float(inside) / 6
            }
        }
        let findings = PictureGeometry.measure(frames)
        #expect(findings.value("geometry.pillarboxed") == 1)
        #expect(findings.value("geometry.borderEdgeWidth")! >= 3)
        #expect(findings.value("geometry.borderNoise")! > 0.5)
    }

    @Test func onlyBlackFramesMeasureNothing() {
        let frames = [SyntheticPicture.frame(width: 64, height: 64) { _, _ in 16 }]
        #expect(PictureGeometry.measure(frames).measured.isEmpty)
    }
}

@Suite struct DetailSpectrumTests {
    private let whole = PictureGeometry.ActiveArea(left: 0, top: 0, width: 640, height: 360)

    @Test func aNativePictureReadsAboutHalfTheBandAndIsNotNoiseLimited() {
        let frame = SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 640, sourceHeight: 360)
        let across = DetailSpectrum.horizontal(frame, in: whole)!
        let down = DetailSpectrum.vertical(frame, in: whole)!
        // A picture's energy falls away with frequency, so even a native
        // one encloses 99.9 % of it well short of the limit. A real 1080p
        // photograph read 0.52; what matters is what an upscale reads
        // against this.
        #expect(across.fraction > 0.4 && across.fraction < 0.6 && !across.noiseLimited)
        #expect(down.fraction > 0.4 && down.fraction < 0.6 && !down.noiseLimited)
    }

    @Test func anUpscaleStopsWhereItsSourceDid() {
        let frame = SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 160, sourceHeight: 90)
        let findings = DetailSpectrum.measure([frame], in: whole)
        let width = findings.value("detail.effectiveWidth", .high)!
        let height = findings.value("detail.effectiveHeight", .high)!
        // A quarter of the size each way reads a quarter of what the
        // native picture does: 0.12 of the frame against 0.48.
        #expect(width > 60 && width < 100)
        #expect(height > 35 && height < 60)
        #expect(findings.value("detail.horizontalFill")! < 0.16)
        #expect(findings.value("detail.noiseLimitedShare") == 0)
    }

    @Test func aReadingThatLiesInTheNoiseIsWithheld() {
        // The same upscale with white noise laid over it afterwards. The
        // spectrum levels off into the noise long before the top of the
        // band and the energy cutoff lands out there, describing the noise.
        let clean = SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 160, sourceHeight: 90)
        var noise = SyntheticPicture.Noise()
        let noisy = PictureFrame(width: 640, height: 360, luma: clean.luma.map { $0 + noise.signedUnit() * 14 })
        let cutoff = DetailSpectrum.horizontal(noisy, in: whole)!
        #expect(cutoff.noiseLimited)
        #expect(cutoff.noiseMeetsFraction < 0.5)
        let findings = DetailSpectrum.measure([noisy], in: whole)
        #expect(findings.value("detail.noiseLimitedShare") == 1)
        #expect(findings.value("detail.effectiveWidth", .high) == nil)
        #expect(findings.value("detail.energyWidth", .high)! > 500)  // kept, as the raw reading
    }

    @Test func softerAcrossThanDownIsReportedAsAShape() {
        // A quarter of the width and half the height: what tape leaves.
        let frame = SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 160, sourceHeight: 180)
        let findings = DetailSpectrum.measure([frame], in: whole)
        #expect(findings.value("detail.horizontalToVerticalFill")! < 0.75)
    }

    @Test func aSteepSpectrumWithNoStepIsReadByItsEnergy() {
        // Power falling as 1/f^3 to a hard stop at a quarter of the band:
        // the step is there, but the energy reading finds the limit too.
        var power = [Float](repeating: 0, count: 512)
        for bin in 1..<128 { power[bin] = 1e9 / pow(Float(bin), 3) }
        for bin in 128..<512 { power[bin] = 1e-3 }
        let cutoff = DetailSpectrum.cutoff(ofPower: power)!
        #expect(cutoff.fraction < 0.26)
        #expect(cutoff.cliffFraction > 0.2 && cutoff.cliffFraction < 0.3)
    }

    @Test func aFlatFrameHasNoCutoff() {
        let frame = SyntheticPicture.frame(width: 640, height: 360) { _, _ in 128 }
        #expect(DetailSpectrum.horizontal(frame, in: whole) == nil)
    }

    @Test func summariesCarryFramesMedianAndHigh() {
        var findings = SignalFindings()
        FrameSummary.record("k", [(0, 1), (1, 2), (2, 3), (3, 4), (4, 100)], into: &findings)
        #expect(findings.measured.count { $0.scope == .frame } == 5)
        #expect(findings.value("k", .median) == 3)
        #expect(abs(findings.value("k", .high)! - 61.6) < 1e-9)
    }
}

@Suite struct FrameTriageTests {
    @Test func blackAndFlatFramesAreRejectedAndPictureIsNot() {
        var noise = SyntheticPicture.Noise()
        #expect(FrameTriage.rejection(of: SyntheticPicture.frame(width: 64, height: 64) { _, _ in 17 }) == .black)
        #expect(FrameTriage.rejection(of: SyntheticPicture.frame(width: 64, height: 64) { _, _ in 128 }) == .flat)
        #expect(FrameTriage.rejection(of: SyntheticPicture.frame(width: 64, height: 64) { _, _ in noise.next() }) == nil)
    }
}

@Suite struct PictureStillsStageTests {
    @Test func theStageDecodesAndMeasuresASynthesizedClip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-stills-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clip.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await DemoMediaFactory.writeVideo(to: url, seconds: 4)

        let findings = try await PictureStillsStage().examine(SignalStageInput(url: url, kind: .video))
        #expect(findings.value("sampling.stillsUsed")! >= 6)
        #expect(findings.value("geometry.activeWidth") == 320)
        #expect(findings.value("geometry.activeHeight") == 180)
        #expect(findings.value("geometry.pillarboxed") == 0)
        let width = findings.value("detail.effectiveWidth", .high)!
        #expect(width > 0 && width <= 320)
    }
}
