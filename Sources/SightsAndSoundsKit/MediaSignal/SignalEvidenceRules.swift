import Foundation

/// Turns findings into evidence. Every threshold the job has is in this
/// file, each with the reading it came from, so that calibrating against
/// files whose history is known means editing numbers here and nowhere
/// else. Raise `SignalRules.version` when any of them changes.
public enum SignalEvidenceRules {
    /// 0 below `from`, 1 above `to`, straight between. `from` may exceed
    /// `to`, for signs that grow as a number falls.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard from != to else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    public static func evidence(from facts: SignalFacts) -> [SignalEvidence] {
        var found: [SignalEvidence] = []
        func add(_ key: String, _ about: SignalEvidence.About, _ strength: Double, _ detail: String) {
            guard strength > 0.05 else { return }
            found.append(SignalEvidence(key: key, about: about, strength: strength, detail: detail))
        }
        func text(_ number: Double, _ places: Int = 2) -> String { String(format: "%.\(places)f", number) }

        // MARK: What the file admits to

        let writers = [
            facts.declared["video.encoderSettings"], facts.declared["container.writingApplication"],
            facts.declared["mediainfo.general.Encoded_Application"], facts.declared["ffprobe.format.encoder"],
            facts.declared["mediainfo.video.Encoded_Library_Name"],
        ].compactMap { $0 }
        let transcoders = ["handbrake", "lavf", "x264", "x265", "ffmpeg", "libav", "mencoder", "vidcoder"]
        if let named = writers.first(where: { writer in transcoders.contains { writer.lowercased().contains($0) } }) {
            // The one thing here that is a fact and not a reading.
            add("transcoderNamed", .processing, 1, "written by \(named.prefix(60))")
        }
        if let rotation = facts.number("video.rotationDegrees"), rotation != 0 {
            add("rotatedPicture", .source, 0.8, "stored rotated \(Int(rotation)) degrees, as a phone does")
        }
        if let aspect = facts.declared["video.pixelAspectRatio"], aspect != "1:1" {
            add("nonSquarePixels", .source, 0.8, "pixel aspect ratio \(aspect), a standard-definition habit")
        }
        if facts.declared["video.colorTagged"] == "no" {
            add("untaggedColour", .encode, 0.6, "no colour primaries, transfer or matrix declared")
        }
        if facts.declared["video.hdrMasteringDisplay"] != nil || facts.declared["video.dolbyVision"] != nil {
            add("hdrMetadata", .source, 0.9, "HDR mastering metadata present")
        }

        // MARK: Frame timing

        if let constant = facts.value("timing.constantFrameRate"), constant == 0,
           let regular = facts.value("timing.regularIntervalFraction") {
            add("variableFrameRate", .source, ramp(regular, from: 0.98, to: 0.8),
                "only \(text(regular * 100, 0)) % of frame intervals are the usual one")
        }
        if let family = facts.value("timing.rateFamily") {
            switch family {
            case 23.9...24.1: add("filmFrameRate", .source, 0.6, "\(text(family, 3)) frames a second")
            case 24.9...25.1, 49.9...50.1: add("fiftyHertzRate", .source, 0.6, "\(text(family, 2)) frames a second: a 50 Hz standard")
            case 29.9..<29.99, 59.9..<59.99:
                add("sixtyHertzRate", .source, 0.6, "\(text(family, 2)) frames a second: a 60 Hz standard")
            default: break
            }
        }
        if let rate = facts.value("timing.typicalFrameRate"), rate < 20 {
            add("lowFrameRate", .source, ramp(rate, from: 20, to: 15), "\(text(rate, 1)) frames a second")
        }
        if let bits = facts.value("timing.bitsPerPixel") {
            add("starvedBitrate", .encode, ramp(bits, from: 0.04, to: 0.015), "\(text(bits, 3)) bits per pixel")
        }

        // MARK: Geometry

        let aspect = facts.value("geometry.activeAspectRatio")
        if facts.value("geometry.pillarboxed") == 1, let aspect, let bars = facts.value("geometry.pillarboxFraction") {
            let fourByThree = abs(aspect - 4.0 / 3) < 0.06 || abs(aspect - 1.375) < 0.04
            add("pillarboxed", .source, fourByThree ? 1 : 0.6,
                "bars fill \(text(bars * 100, 0)) % of the width; the picture inside is \(text(aspect)):1")
        }
        if facts.value("geometry.letterboxed") == 1, let aspect, let bars = facts.value("geometry.letterboxFraction") {
            add("letterboxed", .source, 0.9,
                "bars fill \(text(bars * 100, 0)) % of the height; the picture inside is \(text(aspect)):1")
        }
        if let aspect, aspect >= 1.8 {
            add("cinemaAspect", .source, ramp(aspect, from: 1.8, to: 2.3), "active picture \(text(aspect)):1")
        }
        if let aspect, aspect < 1.45, facts.value("geometry.pillarboxed") != 1 {
            add("fourByThreeFrame", .source, 0.7, "the whole frame is \(text(aspect)):1")
        }
        if let edge = facts.value("geometry.borderEdgeWidth") {
            add("barsScaledWithPicture", .processing, ramp(edge, from: 1.5, to: 4),
                "the bars' inner edge is \(text(edge, 0)) pixels wide; painted bars have none")
        }
        if let noise = facts.value("geometry.borderNoise") {
            add("barsCarryNoise", .source, ramp(noise, from: 0.4, to: 1.5),
                "bars have noise of \(text(noise)) code values; painted bars have none")
        }

        // MARK: Detail

        // A native picture read 0.48 to 0.74 of its frame on synthetic
        // material and a 2x upscale 0.24 to 0.31. Uncalibrated on real files.
        let limited = (facts.value("detail.noiseLimitedShare") ?? 0) > 0.5
        if limited {
            add("detailHiddenByNoise", .encode, 0.8, "the spectrum runs into noise; effective size cannot be read")
        }
        let fillAcross = facts.value("detail.horizontalFill"), fillDown = facts.value("detail.verticalFill")
        if let fill = [fillAcross, fillDown].compactMap({ $0 }).max(), !limited {
            let width = facts.value("detail.effectiveWidth", .high), height = facts.value("detail.effectiveHeight", .high)
            let size = "detail runs out near \(text(width ?? 0, 0)) x \(text(height ?? 0, 0))"
            add("detailBelowFrame", .processing, ramp(fill, from: 0.42, to: 0.24), "\(size), \(text(fill)) of the frame")
            add("detailFillsFrame", .source, ramp(fill, from: 0.42, to: 0.6), "\(size), \(text(fill)) of the frame")
            // Detail that fills a frame says "not scaled up". Only in a big
            // frame does it also say "high definition".
            if let lines = facts.value("geometry.activeHeight") ?? facts.number("video.encodedHeight") {
                let filled = ramp(fill, from: 0.42, to: 0.6)
                add("highDefinitionDetail", .source, filled * ramp(lines, from: 600, to: 700),
                    "\(size) in a picture \(text(lines, 0)) lines high")
                add("ultraHighDefinitionDetail", .source, filled * ramp(lines, from: 1500, to: 2000),
                    "\(size) in a picture \(text(lines, 0)) lines high")
                add("standardDefinitionDetail", .source, filled * ramp(lines, from: 620, to: 580),
                    "\(size) in a picture \(text(lines, 0)) lines high")
            }
        }
        if let shape = facts.value("detail.horizontalToVerticalFill"), !limited {
            add("softerAcrossThanDown", .source, ramp(shape, from: 0.8, to: 0.5),
                "\(text(shape)) as much detail across as down, the shape tape leaves")
            add("softerDownThanAcross", .processing, ramp(shape, from: 1.35, to: 1.9),
                "\(text(shape)) times the detail across as down, the shape a discarded field leaves")
        }

        // MARK: Colour

        let chromaLimited = (facts.value("chroma.noiseLimitedShare") ?? 0) > 0.5
        if let fill = facts.value("chroma.horizontalFill", .high), !chromaLimited {
            add("colourDetailVeryLow", .source, ramp(fill, from: 0.3, to: 0.12),
                "colour uses \(text(fill)) of what its planes could hold across")
        }
        if let shape = facts.value("chroma.horizontalToVerticalFill"), !chromaLimited {
            add("colourSofterAcross", .source, ramp(shape, from: 0.7, to: 0.35),
                "colour has \(text(shape)) as much detail across as down")
        }
        if let offset = facts.value("chroma.horizontalOffsetSamples") {
            add("colourDisplaced", .source, ramp(abs(offset), from: 0.7, to: 2),
                "colour sits \(text(offset, 1)) samples from the brightness it belongs to")
        }
        if facts.value("colour.monochrome") == 1 { add("monochrome", .source, 0.9, "no colour in the picture") }
        if facts.value("colour.usesFullRange") == 1, facts.declared["video.range"] != "full" {
            add("rangeBeyondItsTag", .processing, 0.8, "samples reach full range in a file not tagged full range")
        }
        if facts.value("colour.washedOut") == 1 {
            // Weak: a sunlit scene with no shadows reads the same way.
            add("washedOut", .processing, 0.4, "the picture never nears black or white in any sampled frame")
        }
        if facts.declared["video.bitDepth"] == "10", let used = facts.value("colour.lowBitsUsedShare") {
            add("paddedBitDepth", .processing, ramp(used, from: 0.05, to: 0.005),
                "\(text(used * 100, 1)) % of samples use the two extra bits")
            add("trueTenBit", .source, ramp(used, from: 0.2, to: 0.5), "\(text(used * 100, 0)) % of samples use the two extra bits")
        }

        // MARK: Noise

        if let sigma = facts.value("noise.sigma", .median) {
            add("noisyPicture", .source, ramp(sigma, from: 1.2, to: 3.5), "noise of \(text(sigma)) code values in flat areas")
            add("cleanPicture", .source, ramp(sigma, from: 0.8, to: 0.3), "noise of \(text(sigma)) code values in flat areas")
        }
        if let along = facts.value("noise.anisotropy") {
            add("noiseRunsAlongLines", .source, ramp(along, from: 0.15, to: 0.4),
                "noise correlates \(text(along)) more along lines than between them")
        }
        if let across = facts.value("noise.horizontalCorrelation"), let down = facts.value("noise.verticalCorrelation") {
            add("noiseScaledWithPicture", .processing, ramp(min(across, down), from: 0.3, to: 0.55),
                "noise correlates \(text(across)) across and \(text(down)) down: coarser than a pixel")
        }
        if let ratio = facts.value("noise.midtoneToShadowRatio") {
            add("noiseHeaviestInMidtones", .source, ramp(ratio, from: 1.2, to: 1.8), "mid-tone noise \(text(ratio)) times the shadows'")
            add("noiseHeaviestInShadows", .source, ramp(ratio, from: 0.85, to: 0.55), "mid-tone noise \(text(ratio)) times the shadows'")
        }

        // MARK: Cadence and interlacing

        if let period = facts.value("cadence.duplicatePeriod"), let share = facts.value("cadence.duplicateFraction", .median) {
            let key = period == 5 ? "repeatsOneInFive" : period == 2 ? "repeatsEveryOther" : "repeatsOnABeat"
            add(key, .processing, 0.95, "\(text(share * 100, 0)) % of frames repeat the last, one in every \(Int(period))")
        } else if let share = facts.value("cadence.duplicateFraction", .median) {
            add("repeatsWithoutABeat", .source, ramp(share, from: 0.06, to: 0.2), "\(text(share * 100, 0)) % of frames repeat the last, on no beat")
        }
        if facts.value("cadence.duplicatePeriod") == nil, facts.value("cadence.motionPeriod") == 5 {
            add("motionBeatOfFive", .processing, 0.7, "motion comes in a repeating pattern five frames long")
        }
        if let blended = facts.value("cadence.blendedFraction", .median) {
            add("blendedFrames", .processing, ramp(blended, from: 0.1, to: 0.35), "\(text(blended * 100, 0)) % of frames are a mix of their neighbours")
        }
        if let combed = facts.value("interlace.combedFrameFraction", .median) {
            add("combedFrames", .source, ramp(combed, from: 0.05, to: 0.3), "\(text(combed * 100, 0)) % of frames show comb teeth where there is motion")
        }
        if facts.value("interlace.combedPeriod") == 5 {
            add("combedOnAFilmBeat", .source, 0.9, "combed frames come two in every five")
        }
        if let pairs = facts.value("interlace.linePairAsymmetry", .median) {
            add("linesInPairs", .processing, ramp(pairs, from: 0.2, to: 0.45), "rows come in matching pairs (\(text(pairs)))")
        }
        if let flutter = facts.value("interlace.bobFlutter", .median) {
            add("bobFlutter", .processing, ramp(flutter, from: 0.75, to: 0.92), "still areas flip between two pictures frame to frame")
        }
        if let flicker = facts.value("temporal.lumaFlicker", .median) {
            add("brightnessFlicker", .source, ramp(flicker, from: 0.8, to: 2.5), "brightness jumps \(text(flicker)) code values frame to frame")
        }

        // MARK: Sound

        if let band = facts.value("audio.bandwidth40Hz") {
            add("narrowSound", .source, ramp(band, from: 14_000, to: 9_000), "sound reaches \(text(band / 1000, 1)) kHz")
            add("fullBandSound", .source, ramp(band, from: 17_000, to: 19_500), "sound reaches \(text(band / 1000, 1)) kHz")
            if let steep = facts.value("audio.rolloffSteepnessDbPerKhz"), band < 19_000 {
                add("soundStopsAtAWall", .processing, ramp(steep, from: 15, to: 35), "falls \(text(steep, 0)) dB in a kilohertz: a codec's low-pass")
                add("soundRollsAwayGently", .source, ramp(steep, from: 12, to: 5) * ramp(band, from: 17_000, to: 13_000),
                    "falls \(text(steep, 0)) dB in a kilohertz: an analog chain's slope")
            }
        }
        if let whistle = facts.value("audio.lineWhistleHz"), let level = facts.value("audio.lineWhistleDb") {
            add("lineWhistle", .source, ramp(level, from: 10, to: 18),
                "a \(text(whistle, 0)) Hz tone \(text(level, 0)) dB above its surroundings: a \(whistle < 15_700 ? "625" : "525")-line monitor or recorder")
        }
        let hum50 = facts.value("audio.hum50Db") ?? 0, hum60 = facts.value("audio.hum60Db") ?? 0
        if max(hum50, hum60) > 0 {
            add("mainsHum", .source, ramp(max(hum50, hum60), from: 10, to: 20),
                "\(hum50 > hum60 ? 50 : 60) Hz hum \(text(max(hum50, hum60), 0)) dB above the noise in quiet passages")
        }
        if let floor = facts.value("audio.noiseFloorDb") {
            add("hissyQuietPassages", .source, ramp(floor, from: -58, to: -45), "quietest passages sit at \(text(floor, 0)) dBFS")
        }
        if facts.value("audio.monoAsStereo") == 1 { add("monoAsStereo", .source, 0.9, "both channels carry the same sound") }
        if let clipped = facts.value("audio.clippedFraction") {
            add("clippedSound", .source, ramp(clipped, from: 0.0002, to: 0.002), "\(text(clipped * 100, 2)) % of samples are flattened peaks")
        }
        return found
    }
}
