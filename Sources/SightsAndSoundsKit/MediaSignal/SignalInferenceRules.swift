import Foundation

public enum SignalRules {
    /// Raise when a threshold or a weight changes. Conclusions drawn by an
    /// older version are re-drawn from the stored findings; no file is
    /// decoded again.
    public static let version = 1

    /// Below this a category is not worth saying.
    static let reportable = 0.35
}

/// Turns evidence into conclusions, with the evidence attached.
///
/// Deliberately a table of weights and nothing cleverer. Each category
/// lists the signs that speak for it and against it, and how much each is
/// worth. Signs for combine as independent chances (two signs worth a half
/// each give three quarters, not one); signs against scale the result
/// down. Every number can be read, argued with, and corrected against a
/// file whose history is known, which no trained model would allow, and
/// until there is such a set of files these weights are informed guesses.
public enum SignalInferenceRules {
    struct Rule {
        var kind: SignalInference.Kind
        var category: String
        var supports: [String: Double]
        var contradicts: [String: Double] = [:]
        /// Whether the rule means anything for a file with no picture.
        var forSoundAlone = false
    }

    static let rules: [Rule] = [
        // MARK: What the material originally was

        Rule(kind: .sourceCharacter, category: "Film", supports: [
            "repeatsOneInFive": 0.55, "combedOnAFilmBeat": 0.65, "motionBeatOfFive": 0.4,
            "filmFrameRate": 0.35, "cinemaAspect": 0.4, "noiseHeaviestInMidtones": 0.3,
            "brightnessFlicker": 0.15, "monochrome": 0.15,
        ], contradicts: [
            "variableFrameRate": 0.6, "rotatedPicture": 0.8, "lineWhistle": 0.2, "noiseRunsAlongLines": 0.3,
        ]),
        Rule(kind: .sourceCharacter, category: "Analog Video", supports: [
            "lineWhistle": 0.6, "noiseRunsAlongLines": 0.45, "colourSofterAcross": 0.4,
            "softerAcrossThanDown": 0.4, "colourDisplaced": 0.3, "mainsHum": 0.3,
            "soundRollsAwayGently": 0.3, "hissyQuietPassages": 0.2, "combedFrames": 0.25,
            "barsCarryNoise": 0.3, "nonSquarePixels": 0.15, "fourByThreeFrame": 0.15, "pillarboxed": 0.15,
        ], contradicts: [
            "highDefinitionDetail": 0.5, "hdrMetadata": 0.95, "trueTenBit": 0.6, "rotatedPicture": 0.8,
            "cleanPicture": 0.35, "fullBandSound": 0.3,
        ]),
        // Consumer tape in particular: analog video, plus the signs only
        // colour-under recording and a linear sound track leave.
        Rule(kind: .sourceCharacter, category: "VHS-like", supports: [
            "colourDetailVeryLow": 0.55, "colourSofterAcross": 0.35, "softerAcrossThanDown": 0.45,
            "narrowSound": 0.4, "noiseRunsAlongLines": 0.4, "colourDisplaced": 0.3,
            "lineWhistle": 0.3, "hissyQuietPassages": 0.25, "monoAsStereo": 0.15, "noisyPicture": 0.2,
        ], contradicts: [
            "highDefinitionDetail": 0.7, "hdrMetadata": 0.95, "trueTenBit": 0.7, "rotatedPicture": 0.8,
            "cleanPicture": 0.5, "fullBandSound": 0.5,
        ]),
        Rule(kind: .sourceCharacter, category: "Digital SD", supports: [
            "nonSquarePixels": 0.5, "pillarboxed": 0.35, "fourByThreeFrame": 0.3, "detailBelowFrame": 0.35,
            "standardDefinitionDetail": 0.45,
            "combedFrames": 0.3, "linesInPairs": 0.25, "cleanPicture": 0.2,
            "fiftyHertzRate": 0.1, "sixtyHertzRate": 0.1,
        ], contradicts: [
            "noiseRunsAlongLines": 0.5, "colourDetailVeryLow": 0.5, "lineWhistle": 0.5,
            "highDefinitionDetail": 0.4, "hdrMetadata": 0.95, "lowFrameRate": 0.4, "rotatedPicture": 0.8,
        ]),
        Rule(kind: .sourceCharacter, category: "Early Web / Low-Bitrate Digital", supports: [
            "repeatsEveryOther": 0.6, "lowFrameRate": 0.6, "narrowSound": 0.35, "soundStopsAtAWall": 0.25,
            "detailBelowFrame": 0.3, "repeatsWithoutABeat": 0.3, "monoAsStereo": 0.15, "variableFrameRate": 0.15,
        ], contradicts: [
            "highDefinitionDetail": 0.6, "lineWhistle": 0.4, "noiseRunsAlongLines": 0.4,
            "hdrMetadata": 0.95, "trueTenBit": 0.7, "combedFrames": 0.4,
        ]),
        Rule(kind: .sourceCharacter, category: "HD Digital", supports: [
            "highDefinitionDetail": 0.65, "noiseHeaviestInShadows": 0.3, "fullBandSound": 0.25,
            "rotatedPicture": 0.4, "variableFrameRate": 0.2,
        ], contradicts: [
            "standardDefinitionDetail": 0.8,
            "detailBelowFrame": 0.8, "pillarboxed": 0.4, "nonSquarePixels": 0.6, "lineWhistle": 0.6,
            "colourDetailVeryLow": 0.6, "noiseRunsAlongLines": 0.5, "narrowSound": 0.3,
        ]),
        Rule(kind: .sourceCharacter, category: "UHD Digital", supports: [
            "ultraHighDefinitionDetail": 0.7, "hdrMetadata": 0.6, "trueTenBit": 0.4,
        ], contradicts: [
            "detailBelowFrame": 0.7, "paddedBitDepth": 0.7, "pillarboxed": 0.3,
        ]),

        // MARK: What has been done to it

        Rule(kind: .history, category: "Re-encoded by a transcoder", supports: ["transcoderNamed": 1],
             forSoundAlone: true),
        Rule(kind: .history, category: "Scaled up", supports: [
            "detailBelowFrame": 0.75, "noiseScaledWithPicture": 0.5, "barsScaledWithPicture": 0.4,
        ], contradicts: ["detailFillsFrame": 0.8]),
        Rule(kind: .history, category: "Bars encoded into the picture", supports: [
            "pillarboxed": 0.9, "letterboxed": 0.9,
        ]),
        Rule(kind: .history, category: "Interlaced frames stored as progressive", supports: ["combedFrames": 0.9]),
        Rule(kind: .history, category: "Deinterlaced", supports: [
            "linesInPairs": 0.7, "bobFlutter": 0.6, "softerDownThanAcross": 0.45, "blendedFrames": 0.3,
        ], contradicts: ["combedFrames": 0.6]),
        Rule(kind: .history, category: "Telecined film", supports: [
            "combedOnAFilmBeat": 0.85, "repeatsOneInFive": 0.5, "motionBeatOfFive": 0.45,
        ]),
        Rule(kind: .history, category: "Frame rate converted", supports: [
            "repeatsOneInFive": 0.7, "repeatsEveryOther": 0.8, "repeatsOnABeat": 0.7,
            "blendedFrames": 0.6, "motionBeatOfFive": 0.4,
        ]),
        Rule(kind: .history, category: "Tape-derived", supports: [
            "noiseRunsAlongLines": 0.5, "colourDetailVeryLow": 0.5, "lineWhistle": 0.45,
            "colourDisplaced": 0.3, "soundRollsAwayGently": 0.3, "hissyQuietPassages": 0.25, "barsCarryNoise": 0.3,
            "mainsHum": 0.3, "narrowSound": 0.25,
        ], contradicts: ["highDefinitionDetail": 0.6, "cleanPicture": 0.4, "fullBandSound": 0.4], forSoundAlone: true),
        Rule(kind: .history, category: "Range converted wrongly", supports: [
            "rangeBeyondItsTag": 0.8, "washedOut": 0.3,
        ]),
        Rule(kind: .history, category: "Bit depth padded", supports: ["paddedBitDepth": 0.9]),
        Rule(kind: .history, category: "Sound through an earlier lossy codec", supports: [
            "soundStopsAtAWall": 0.7,
        ], forSoundAlone: true),
    ]

    /// `hasPicture` is false for a sound-only item, which has no picture
    /// origin to conclude about: only the rules about sound and about the
    /// file itself are asked.
    public static func conclusions(from evidence: [SignalEvidence], hasPicture: Bool = true) -> [SignalConclusion] {
        let strengths = Dictionary(evidence.map { ($0.key, $0.strength) }) { first, _ in first }
        var drawn: [SignalConclusion] = []
        for rule in rules where hasPicture || rule.forSoundAlone {
            var miss = 1.0
            var supportedBy: [String] = []
            for (key, weight) in rule.supports.sorted(by: { $0.key < $1.key }) {
                guard let strength = strengths[key], strength * weight > 0.02 else { continue }
                miss *= 1 - strength * weight
                supportedBy.append(key)
            }
            guard !supportedBy.isEmpty else { continue }
            var confidence = 1 - miss
            var contradictedBy: [String] = []
            for (key, weight) in rule.contradicts.sorted(by: { $0.key < $1.key }) {
                guard let strength = strengths[key], strength * weight > 0.02 else { continue }
                confidence *= 1 - strength * weight
                contradictedBy.append(key)
            }
            guard confidence >= SignalRules.reportable else { continue }
            drawn.append(SignalConclusion(
                kind: rule.kind, category: rule.category, confidence: confidence,
                supportedBy: supportedBy, contradictedBy: contradictedBy))
        }

        // "Unknown" is a conclusion too, and often the right one: nothing
        // cleared the bar, or two incompatible origins both did and neither
        // is clearly ahead.
        let origins = drawn.filter { $0.kind == .sourceCharacter }.sorted { $0.confidence > $1.confidence }
        let compatible: Set<Set<String>> = [["Analog Video", "VHS-like"], ["HD Digital", "UHD Digital"]]
        if !hasPicture {
            // No picture, no picture origin, and no "Unknown" either.
        } else if origins.isEmpty {
            drawn.append(SignalConclusion(
                kind: .sourceCharacter, category: "Unknown", confidence: 1, supportedBy: [], contradictedBy: []))
        } else if origins.count >= 2, origins[0].confidence - origins[1].confidence < 0.1,
                  !compatible.contains([origins[0].category, origins[1].category]),
                  // Film that reached us through a video stage is both.
                  !(Set([origins[0].category, origins[1].category]).contains("Film")) {
            drawn.append(SignalConclusion(
                kind: .sourceCharacter, category: "Unknown",
                confidence: 1 - (origins[0].confidence - origins[1].confidence) * 5,
                supportedBy: origins[0].supportedBy, contradictedBy: origins[1].supportedBy))
        }
        return drawn.sorted { ($0.kind.rawValue, -$0.confidence) < ($1.kind.rawValue, -$1.confidence) }
    }

    /// Evidence and conclusions for one item's stored findings.
    public static func conclude(_ facts: SignalFacts) -> (evidence: [SignalEvidence], conclusions: [SignalConclusion]) {
        let evidence = SignalEvidenceRules.evidence(from: facts)
        // The declared stage counts video tracks; a file it has not seen,
        // or has seen a picture in, is treated as having one.
        let hasPicture = facts.declared["container.videoTrackCount"] != "0"
        return (evidence, conclusions(from: evidence, hasPicture: hasPicture))
    }
}
