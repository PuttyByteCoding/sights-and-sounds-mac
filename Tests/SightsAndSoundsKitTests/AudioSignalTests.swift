import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Tones and noise of known level and bandwidth, so the expected readings
/// are arithmetic.
enum SyntheticSound {
    static func sine(_ hertz: Double, amplitude: Float, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * hertz * Double($0) / sampleRate)) }
    }

    static func noise(amplitude: Float, seconds: Double, sampleRate: Double = 48_000, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amplitude * (Float(state >> 40 & 0xFFFF) / 32_767.5 - 1)
        }
    }

    /// A crude low-pass: a moving average `taps` long, applied four times,
    /// which puts its sidelobes more than 50 dB down.
    static func lowPassed(_ samples: [Float], taps: Int) -> [Float] {
        func once(_ input: [Float]) -> [Float] {
            var sum: Float = 0
            return input.indices.map { index in
                sum += input[index]
                if index >= taps { sum -= input[index - taps] }
                return sum / Float(taps)
            }
        }
        return once(once(once(once(samples))))
    }

    /// Feed in pieces of uneven size, as a decoder would.
    static func meter(left: [Float], right: [Float]?, sampleRate: Double = 48_000) -> SignalFindings {
        let meter = AudioSignalMeter(sampleRate: sampleRate, channels: right == nil ? 1 : 2)!
        var offset = 0
        var piece = 3000
        while offset < left.count {
            let end = min(offset + piece, left.count)
            meter.consume(left: Array(left[offset..<end]), right: right.map { Array($0[offset..<end]) })
            offset = end
            piece = piece == 3000 ? 4111 : 3000
        }
        return meter.findings()
    }
}

@Suite struct AudioSignalMeterTests {

    @Test func aStereoSineReadsItsOwnLevelInLufs() {
        // EBU Tech 3341, case 1: a 1 kHz stereo sine at -23 dBFS is -23 LUFS.
        let amplitude = Float(pow(10, -23.0 / 20))
        let tone = SyntheticSound.sine(1000, amplitude: amplitude, seconds: 20)
        let findings = SyntheticSound.meter(left: tone, right: tone)
        #expect(abs(findings.value("audio.integratedLoudnessLufs")! + 23) < 0.1)
        #expect(abs(findings.value("audio.peakDb")! + 23) < 0.05)
        #expect(abs(findings.value("audio.rmsDb")! + 26.01) < 0.05)
        #expect(findings.value("audio.loudnessRangeLu")! < 0.1)
    }

    @Test func theRelativeGateIgnoresAQuietStretch() {
        // Tech 3341, case 3 in spirit: -36, then -23, then -36. The quiet
        // parts are more than 10 LU down and gate out.
        func tone(_ level: Double, _ seconds: Double) -> [Float] {
            SyntheticSound.sine(1000, amplitude: Float(pow(10, level / 20)), seconds: seconds)
        }
        let programme = tone(-36, 10) + tone(-23, 60) + tone(-36, 10)
        let findings = SyntheticSound.meter(left: programme, right: programme)
        #expect(abs(findings.value("audio.integratedLoudnessLufs")! + 23) < 0.1)
    }

    @Test func kWeightingHoldsAtAnotherSampleRate() {
        let amplitude = Float(pow(10, -23.0 / 20))
        let tone = SyntheticSound.sine(1000, amplitude: amplitude, seconds: 20, sampleRate: 44_100)
        let findings = SyntheticSound.meter(left: tone, right: tone, sampleRate: 44_100)
        #expect(abs(findings.value("audio.integratedLoudnessLufs")! + 23) < 0.1)
    }

    @Test func identicalChannelsAreMonoPassedOffAsStereo() {
        let sound = SyntheticSound.noise(amplitude: 0.3, seconds: 4)
        let same = SyntheticSound.meter(left: sound, right: sound)
        #expect(same.value("audio.monoAsStereo") == 1)
        #expect(abs(same.value("audio.channelCorrelation")! - 1) < 1e-6)

        let other = SyntheticSound.noise(amplitude: 0.3, seconds: 4, seed: 99)
        let different = SyntheticSound.meter(left: sound, right: other)
        #expect(different.value("audio.monoAsStereo") == 0)
        #expect(abs(different.value("audio.channelCorrelation")!) < 0.05)

        let inverted = SyntheticSound.meter(left: sound, right: sound.map { -$0 })
        #expect(inverted.value("audio.channelCorrelation")! < -0.999)
    }

    @Test func flattenedPeaksAreCountedAndLoudSamplesAreNot() {
        let clean = SyntheticSound.sine(440, amplitude: 0.999, seconds: 2)
        #expect(SyntheticSound.meter(left: clean, right: nil).value("audio.clippedRuns") == 0)

        let driven = SyntheticSound.sine(440, amplitude: 1.6, seconds: 2).map { max(-1, min(1, $0)) }
        let findings = SyntheticSound.meter(left: driven, right: nil)
        // Two flattened peaks a cycle.
        #expect(abs(findings.value("audio.clippedRuns")! - 440 * 2 * 2) <= 2)
        #expect(findings.value("audio.clippedFraction")! > 0.3)
    }

    @Test func bandwidthIsReadFromTheLongTermSpectrum() {
        let full = SyntheticSound.noise(amplitude: 0.3, seconds: 8)
        let wide = SyntheticSound.meter(left: full, right: nil)
        #expect(wide.value("audio.rolloffHz")! > 23_000)
        #expect(wide.value("audio.nyquistFill")! > 0.97)

        // A nine-tap average has its first null at 5.3 kHz and little
        // above it: the shape of a narrow analog channel.
        let narrow = SyntheticSound.meter(left: SyntheticSound.lowPassed(full, taps: 9), right: nil)
        #expect(narrow.value("audio.bandwidth40Hz")! < 6_000)
        #expect(narrow.value("audio.bandwidth40Hz")! > 3_000)
    }

    @Test func aLineWhistleIsFoundAndNamesItsStandard() {
        let programme = SyntheticSound.noise(amplitude: 0.2, seconds: 8)
        let whistle = SyntheticSound.sine(15_625, amplitude: 0.01, seconds: 8)
        let findings = SyntheticSound.meter(left: zip(programme, whistle).map(+), right: nil)
        #expect(findings.value("audio.lineWhistleDb")! > 10)
        #expect(findings.value("audio.lineWhistleHz") == 15_625)

        let without = SyntheticSound.meter(left: programme, right: nil)
        #expect(without.value("audio.lineWhistleDb")! < 10)
        #expect(without.value("audio.lineWhistleHz") == nil)
    }

    @Test func humInTheQuietPassagesNamesItsMainsFrequency() {
        // Loud programme, then a long quiet passage with only hiss and
        // 60 Hz hum with its harmonics.
        let loud = SyntheticSound.noise(amplitude: 0.3, seconds: 4)
        let hiss = SyntheticSound.noise(amplitude: 0.0005, seconds: 24, seed: 7)
        let hum = [60.0, 120, 180].map { SyntheticSound.sine($0, amplitude: 0.002, seconds: 24) }
        let quiet = hiss.indices.map { hiss[$0] + hum[0][$0] + hum[1][$0] + hum[2][$0] }
        let findings = SyntheticSound.meter(left: loud + quiet, right: nil)
        #expect(findings.value("audio.hum60Db")! > 20)
        #expect(findings.value("audio.hum50Db")! < 6)
        #expect(findings.value("audio.noiseFloorDb")! < -50)
    }

    @Test func silenceMeasuresLevelsButNoLoudness() {
        let findings = SyntheticSound.meter(left: [Float](repeating: 0, count: 96_000), right: nil)
        #expect(findings.value("audio.integratedLoudnessLufs") == nil)
        #expect(findings.value("audio.noiseFloorDb") == nil)
        #expect(findings.value("audio.secondsMeasured") == 2)
    }
}

@Suite struct AudioSignalStageTests {
    @Test func theStageDecodesASynthesizedTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-audio-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tone.m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DemoMediaFactory.writeAudio(to: url)

        let findings = try await AudioSignalStage().examine(SignalStageInput(url: url, kind: .audio))
        #expect(findings.value("audio.present") == 1)
        #expect(findings.value("audio.secondsMeasured")! > 1)
        #expect(findings.value("audio.peakDb")! < 0.1)
        #expect(findings.value("audio.integratedLoudnessLufs") != nil)
    }

    @Test func aFileWithNoSoundTrackSaysSoAndDoesNotFail() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-audio-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("silent.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await DemoMediaFactory.writeVideo(to: url, seconds: 1)
        let findings = try await AudioSignalStage().examine(SignalStageInput(url: url, kind: .video))
        #expect(findings.value("audio.present") == 0)
    }
}
