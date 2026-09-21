import Foundation
import Testing
@testable import SightsAndSoundsKit

@Suite struct CadenceReadingTests {
    /// Motion of varying size, so nothing but the inserted beat repeats.
    private func motion(_ count: Int) -> [Double] {
        // Spelled out a step at a time: CI's older compiler gives up on
        // the one-line version.
        (0..<count).map { index -> Double in
            let swell: Double = 2 * sin(Double(index) * 0.37)
            let scatter: Double = Double((index * 7919) % 13) / 10
            return 4 + swell + scatter
        }
    }

    @Test func oneRepeatInFiveIsFilmCarriedAtVideoRate() {
        var differences = motion(150)
        for index in stride(from: 3, to: 150, by: 5) { differences[index] = 0.01 }
        let reading = CadenceReading.read(differences)
        #expect(abs(reading.duplicateFraction - 0.2) < 0.01)
        #expect(reading.duplicatePeriod == 5)
        #expect(reading.duplicateRegularity == 1)
        #expect(reading.motionPeriod == 5)
    }

    @Test func everyOtherFrameRepeatedIsHalfRateVideoPaddedOut() {
        var differences = motion(120)
        for index in stride(from: 1, to: 120, by: 2) { differences[index] = 0 }
        let reading = CadenceReading.read(differences)
        #expect(reading.duplicatePeriod == 2)
        #expect(abs(reading.duplicateFraction - 0.5) < 0.01)
    }

    @Test func ordinaryMotionHasNoBeat() {
        let reading = CadenceReading.read(motion(200))
        #expect(reading.duplicateFraction == 0)
        #expect(reading.duplicatePeriod == nil)
        #expect(reading.motionPeriod == nil)
    }

    @Test func aStillShotIsNotAFileFullOfRepeats() {
        // Motion, then a long hold on a still, then motion again.
        let differences = motion(60) + [Double](repeating: 0, count: 120) + motion(60)
        let reading = CadenceReading.read(differences)
        #expect(reading.duplicateFraction < 0.06)
        #expect(reading.duplicatePeriod == nil)
    }

    @Test func scatteredDroppedFramesAreRepeatsWithoutABeat() {
        var differences = motion(200)
        for index in [7, 31, 32, 80, 123, 170] { differences[index] = 0 }
        let reading = CadenceReading.read(differences)
        #expect(reading.duplicateFraction > 0.02)
        #expect(reading.duplicatePeriod == nil)
    }

    @Test func blendedPulldownLeavesABeatInTheMotionAndNoRepeats() {
        // Big, big, big, small, small: no step is zero.
        let steps: [Double] = [6.0, 6.2, 5.9, 2.9, 3.1]
        let differences = (0..<150).map { index -> Double in
            let wobble: Double = Double(index % 3) / 10
            return steps[index % 5] + wobble
        }
        let reading = CadenceReading.read(differences)
        #expect(reading.duplicateFraction == 0)
        #expect(reading.motionPeriod == 5)
        #expect(reading.motionPeriodStrength > 0.5)
    }

    @Test func cutsAreCountedAndDoNotBecomeTheBeat() {
        var differences = motion(200)
        for index in [40, 95, 160] { differences[index] = 70 }
        let reading = CadenceReading.read(differences)
        #expect(reading.sceneCuts == 3)
        #expect(reading.motionPeriod == nil)
    }
}

@Suite struct SequenceMeterTests {
    static let width = 96, height = 64

    /// A textured bar `position` pixels along, on a textured ground: there
    /// is something to see move, and something that does not.
    static func scene(_ position: Int) -> [Float] {
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let ground = 60 + Float((x * 13 + y * 7) % 23)
                let inBar = x >= position % (width - 20) && x < position % (width - 20) + 20
                luma[y * width + x] = inBar ? 190 + Float((x + y) % 11) : ground
            }
        }
        return luma
    }

    static func frame(_ luma: [Float]) -> PictureFrame {
        PictureFrame(width: width, height: height, luma: luma)
    }

    /// Even rows from one moment, odd rows from the next.
    static func woven(_ first: [Float], _ second: [Float]) -> [Float] {
        var luma = first
        for y in stride(from: 1, to: height, by: 2) {
            for x in 0..<width { luma[y * width + x] = second[y * width + x] }
        }
        return luma
    }

    private func reading(_ frames: [[Float]]) -> SequenceMeter.Reading {
        let meter = SequenceMeter()
        for luma in frames { meter.consume(Self.frame(luma)) }
        return meter.reading()
    }

    @Test func progressiveMotionIsNotCombedBlendedOrDoubled() {
        let reading = reading((0..<48).map { Self.scene($0 * 3) })
        #expect(reading.combedFrameFraction == 0)
        #expect(reading.blendedFraction == 0)
        #expect(reading.linePairAsymmetry < 0.1)
        #expect(reading.cadence.duplicateFraction == 0)
    }

    @Test func fieldsFromTwoMomentsInOneFrameAreCombed() {
        let reading = reading((0..<48).map { Self.woven(Self.scene($0 * 6), Self.scene($0 * 6 + 3)) })
        #expect(reading.combedFrameFraction > 0.9)
        #expect(reading.combedShareHigh > 0.2)
        #expect(reading.combedPeriod == nil)  // every frame, so no beat
    }

    @Test func twoCombedFramesInFiveIsHardTelecine() {
        // Film frames A B C D shown as A, B, B+C, C+D, D.
        let frames = (0..<12).flatMap { group -> [[Float]] in
            let film = (0..<4).map { Self.scene((group * 4 + $0) * 5) }
            return [film[0], film[1], Self.woven(film[1], film[2]), Self.woven(film[2], film[3]), film[3]]
        }
        let reading = reading(frames)
        #expect(abs(reading.combedFrameFraction - 0.4) < 0.08)
        #expect(reading.combedPeriod == 5)
    }

    @Test func aMixOfItsNeighboursIsABlendAndMotionIsNot() {
        // Every third frame is the average of the frames either side.
        var frames: [[Float]] = []
        for index in 0..<24 {
            let before = Self.scene(index * 8), after = Self.scene(index * 8 + 8)
            frames.append(before)
            frames.append(zip(before, after).map { ($0 + $1) / 2 })
            _ = after
        }
        let reading = reading(frames)
        #expect(reading.blendedFraction > 0.4)
    }

    @Test func aDiscardedFieldWithItsLinesDoubledShowsInTheRowPairs() {
        let frames = (0..<30).map { index -> [Float] in
            var luma = Self.scene(index * 3)
            for y in stride(from: 0, to: Self.height - 1, by: 2) {
                for x in 0..<Self.width { luma[(y + 1) * Self.width + x] = luma[y * Self.width + x] }
            }
            return luma
        }
        #expect(reading(frames).linePairAsymmetry > 0.9)
    }

    @Test func aBobbedStillSceneFlutters() {
        // A still scene shown as alternate fields, each line-doubled: the
        // picture flips between two versions half a line apart.
        let still = Self.scene(30)
        func field(_ parity: Int) -> [Float] {
            var luma = still
            for y in 0..<Self.height {
                let source = min(y - (y + parity) % 2 + parity, Self.height - 1)
                for x in 0..<Self.width { luma[y * Self.width + x] = still[max(source, 0) * Self.width + x] }
            }
            return luma
        }
        let reading = reading((0..<40).map { field($0 % 2) })
        #expect(reading.bobFlutter > 0.9)
        #expect(self.reading((0..<40).map { Self.scene($0 * 3) }).bobFlutter < 0.7)
    }

    @Test func brightnessThatJumpsFrameToFrameIsFlicker() {
        let steady = reading((0..<40).map { Self.scene($0 * 3) })
        let flickering = reading((0..<40).map { index in
            Self.scene(index * 3).map { $0 + (index.isMultiple(of: 2) ? 6 : -6) }
        })
        #expect(steady.flicker < 0.5)
        #expect(flickering.flicker > 3)
    }

    @Test func everyFourthFrameSofterIsABeatInSharpness() {
        let frames = (0..<48).map { index -> [Float] in
            let sharp = Self.scene(index * 3)
            guard index % 4 == 3 else { return sharp }
            // Soften across: each pixel averaged with its neighbour.
            return sharp.indices.map { (sharp[$0] + sharp[max($0 - 1, 0)]) / 2 }
        }
        let reading = reading(frames)
        #expect(reading.sharpnessPeriod == 4)
        #expect(reading.sharpnessPeriodStrength > 0.5)
    }

    @Test func aThinMovingLineIsNotACombTooth() {
        // One bright row sweeping down a flat ground: both neighbours of
        // the line differ from it the same way, as a tooth's would, but
        // the rows two away do not match it, as a field's would.
        let frames = (0..<40).map { index -> [Float] in
            var luma = [Float](repeating: 80, count: Self.width * Self.height)
            let row = 4 + index % (Self.height - 8)
            for x in 0..<Self.width { luma[row * Self.width + x] = 200 }
            return luma
        }
        #expect(reading(frames).combedFrameFraction == 0)
    }

    @Test func workingFramesCropAndNarrowButKeepEveryRow() {
        let frame = PictureFrame(width: 2000, height: 40, luma: (0..<80_000).map { Float($0 % 2000) })
        let working = frame.working(in: .init(left: 100, top: 4, width: 1800, height: 30), maxWidth: 960)
        #expect(working.width == 900)
        #expect(working.height == 30)
        // Pairs averaged: columns 100 and 101 become 100.5.
        #expect(working.luma[0] == 100.5)
    }
}

@Suite struct PictureSequenceStageTests {
    @Test func windowsFitTheFile() {
        #expect(FrameSampler.windows(durationSeconds: 600).count == 4)
        #expect(FrameSampler.windows(durationSeconds: 600)[0].start == 120)
        let short = FrameSampler.windows(durationSeconds: 20)
        #expect(short.count == 1)
        #expect(short[0].seconds == 16)
        #expect(FrameSampler.windows(durationSeconds: 0).isEmpty)
    }

    @Test func periodsNeedMostWindowsToAgree() {
        func window(_ period: Int?) -> (start: Double, frames: Int, reading: SequenceMeter.Reading) {
            var reading = SequenceMeter.Reading()
            reading.cadence.duplicatePeriod = period
            return (0, 300, reading)
        }
        let agreed = PictureSequenceStage.findings(from: [window(5), window(5), window(nil), window(5)])
        #expect(agreed.value("cadence.duplicatePeriod") == 5)
        let split = PictureSequenceStage.findings(from: [window(5), window(2), window(nil), window(nil)])
        #expect(split.value("cadence.duplicatePeriod") == nil)
    }

    @Test func theStageRunsOnASynthesizedClip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-sequence-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clip.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await DemoMediaFactory.writeVideo(to: url, seconds: 5)
        let findings = try await PictureSequenceStage().examine(SignalStageInput(url: url, kind: .video))
        #expect(findings.value("sampling.windowsUsed") == 1)
        #expect(findings.value("sampling.windowFrames")! >= 24)
        #expect(findings.value("interlace.combedFrameFraction", .median) == 0)
    }
}
