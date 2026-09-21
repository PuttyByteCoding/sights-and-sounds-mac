import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Whole files described by their findings, as the stages would report
/// them. The expectations are about which conclusions come out and which
/// do not; the exact confidences are the weights' business.
@Suite struct SignalInferenceTests {

    private func facts(_ declared: [String: String] = [:], _ build: (inout SignalFindings) -> Void) -> SignalFacts {
        var findings = SignalFindings()
        build(&findings)
        return SignalFacts(declared: declared, findings: findings)
    }

    private func scoped(_ findings: inout SignalFindings, _ key: String, _ value: Double, _ scope: SignalMeasurement.Scope) {
        findings.measured.append(.init(key, value, scope: scope))
    }

    private func confidence(_ conclusions: [SignalConclusion], _ category: String) -> Double? {
        conclusions.first { $0.category == category }?.confidence
    }

    @Test func aTapeCaptureScaledIntoAnHDFrame() {
        let facts = facts(["container.writingApplication": "HandBrake 1.7.0", "video.bitDepth": "8"]) { f in
            f.measure("geometry.pillarboxed", 1)
            f.measure("geometry.pillarboxFraction", 0.25)
            f.measure("geometry.activeAspectRatio", 1.333)
            f.measure("geometry.borderEdgeWidth", 3)
            f.measure("detail.horizontalFill", 0.2)
            f.measure("detail.verticalFill", 0.3)
            f.measure("detail.horizontalToVerticalFill", 0.55)
            f.measure("detail.noiseLimitedShare", 0)
            scoped(&f, "chroma.horizontalFill", 0.08, .high)
            f.measure("chroma.horizontalToVerticalFill", 0.2)
            f.measure("chroma.horizontalOffsetSamples", 1.8)
            scoped(&f, "noise.sigma", 3.1, .median)
            f.measure("noise.anisotropy", 0.38)
            f.measure("audio.bandwidth40Hz", 10_200)
            f.measure("audio.rolloffSteepnessDbPerKhz", 4)
            f.measure("audio.lineWhistleHz", 15_734.27)
            f.measure("audio.lineWhistleDb", 17)
            f.measure("audio.noiseFloorDb", -44)
        }
        let (evidence, conclusions) = SignalInferenceRules.conclude(facts)

        #expect(confidence(conclusions, "VHS-like")! > 0.8)
        #expect(confidence(conclusions, "Analog Video")! > 0.8)
        #expect(confidence(conclusions, "HD Digital") == nil)
        #expect(confidence(conclusions, "Unknown") == nil)  // analog and VHS-like agree
        // Judged on the better of the two directions, since tape is soft
        // across by nature: 0.3 of the frame down, plus soft-edged bars.
        #expect(confidence(conclusions, "Scaled up")! > 0.55)
        #expect(confidence(conclusions, "Tape-derived")! > 0.8)
        #expect(confidence(conclusions, "Bars encoded into the picture")! > 0.8)
        #expect(confidence(conclusions, "Re-encoded by a transcoder") == 1)

        // Every conclusion names evidence that exists.
        let keys = Set(evidence.map(\.key))
        for conclusion in conclusions {
            #expect(!conclusion.supportedBy.isEmpty)
            #expect(Set(conclusion.supportedBy + conclusion.contradictedBy).isSubset(of: keys))
        }
        let whistle = evidence.first { $0.key == "lineWhistle" }
        #expect(whistle?.detail.contains("525-line") == true)
        #expect(whistle?.about == .source)
    }

    @Test func aPhoneClip() {
        let facts = facts(["video.rotationDegrees": "90", "video.bitDepth": "8"]) { f in
            f.measure("timing.constantFrameRate", 0)
            f.measure("timing.regularIntervalFraction", 0.62)
            f.measure("detail.horizontalFill", 0.66)
            f.measure("detail.noiseLimitedShare", 0)
            f.measure("geometry.activeHeight", 1080)
            scoped(&f, "noise.sigma", 0.4, .median)
            f.measure("noise.midtoneToShadowRatio", 0.5)
            f.measure("audio.bandwidth40Hz", 20_500)
        }
        let conclusions = SignalInferenceRules.conclude(facts).conclusions
        #expect(confidence(conclusions, "HD Digital")! > 0.8)
        #expect(confidence(conclusions, "Film") == nil)
        #expect(confidence(conclusions, "VHS-like") == nil)
        #expect(confidence(conclusions, "Scaled up") == nil)
    }

    @Test func aFilmOnDiscWithItsPulldownLeftIn() {
        let facts = facts(["video.pixelAspectRatio": "32:27"]) { f in
            f.measure("geometry.letterboxed", 1)
            f.measure("geometry.letterboxFraction", 0.24)
            f.measure("geometry.activeAspectRatio", 2.35)
            f.measure("timing.rateFamily", 30000.0 / 1001)
            scoped(&f, "interlace.combedFrameFraction", 0.4, .median)
            f.measure("interlace.combedPeriod", 5)
            f.measure("cadence.motionPeriod", 5)
            f.measure("noise.midtoneToShadowRatio", 1.7)
        }
        let conclusions = SignalInferenceRules.conclude(facts).conclusions
        #expect(confidence(conclusions, "Film")! > 0.8)
        #expect(confidence(conclusions, "Telecined film")! > 0.8)
        #expect(confidence(conclusions, "Interlaced frames stored as progressive")! > 0.8)
        // Film that came through a video stage is both; that is not a conflict.
        #expect(confidence(conclusions, "Unknown") == nil)
    }

    @Test func aHalfRateWebClipPaddedOut() {
        let facts = facts { f in
            f.measure("cadence.duplicatePeriod", 2)
            scoped(&f, "cadence.duplicateFraction", 0.5, .median)
            f.measure("detail.horizontalFill", 0.2)
            f.measure("detail.noiseLimitedShare", 0)
            f.measure("audio.bandwidth40Hz", 8_000)
            f.measure("audio.rolloffSteepnessDbPerKhz", 40)
            f.measure("audio.monoAsStereo", 1)
        }
        let conclusions = SignalInferenceRules.conclude(facts).conclusions
        #expect(confidence(conclusions, "Early Web / Low-Bitrate Digital")! > 0.8)
        #expect(confidence(conclusions, "Frame rate converted")! > 0.7)
        #expect(confidence(conclusions, "Sound through an earlier lossy codec")! > 0.6)
    }

    @Test func detailThatFillsASmallFrameIsNotHighDefinition() {
        let facts = facts { f in
            f.measure("detail.horizontalFill", 0.7)
            f.measure("detail.noiseLimitedShare", 0)
            f.measure("geometry.activeHeight", 480)
        }
        let conclusions = SignalInferenceRules.conclude(facts).conclusions
        #expect(confidence(conclusions, "HD Digital") == nil)
        #expect(confidence(conclusions, "Digital SD")! > 0.4)
        #expect(confidence(conclusions, "Scaled up") == nil)
    }

    @Test func aSoundFileIsAskedOnlyAboutItsSound() {
        let facts = facts(["container.videoTrackCount": "0", "container.writingApplication": "Lavf60.3.100"]) { f in
            f.measure("audio.bandwidth40Hz", 9_500)
            f.measure("audio.rolloffSteepnessDbPerKhz", 4)
            f.measure("audio.noiseFloorDb", -42)
            f.measure("audio.hum60Db", 22)
        }
        let conclusions = SignalInferenceRules.conclude(facts).conclusions
        #expect(conclusions.allSatisfy { $0.kind == .history })
        #expect(confidence(conclusions, "Tape-derived")! > 0.6)
        #expect(confidence(conclusions, "Re-encoded by a transcoder") == 1)
    }

    @Test func aSceneWithNoShadowsIsNotARangeError() {
        let facts = facts { f in f.measure("colour.washedOut", 1) }
        #expect(confidence(SignalInferenceRules.conclude(facts).conclusions, "Range converted wrongly") == nil)
    }

    @Test func nothingKnownIsUnknown() {
        let conclusions = SignalInferenceRules.conclude(SignalFacts(findings: SignalFindings())).conclusions
        #expect(conclusions.map(\.category) == ["Unknown"])
        #expect(conclusions[0].confidence == 1)
    }

    @Test func aNoisyFilesDetailIsNotHeldAgainstIt() {
        let facts = facts { f in
            f.measure("detail.noiseLimitedShare", 1)
            // A raw reading is stored either way; the rules must not use it.
            f.measure("detail.horizontalFill", 0.1)
        }
        let evidence = SignalEvidenceRules.evidence(from: facts)
        #expect(evidence.contains { $0.key == "detailHiddenByNoise" })
        #expect(!evidence.contains { $0.key == "detailBelowFrame" })
    }

    @Test func twoIncompatibleOriginsNeckAndNeckAreUnknown() {
        // Anamorphic and pillarboxed says disc; every other frame repeated
        // with narrow sound says early web. Neither speaks against the other.
        let evidence = [
            SignalEvidence(key: "nonSquarePixels", about: .source, strength: 1, detail: ""),
            SignalEvidence(key: "pillarboxed", about: .source, strength: 1, detail: ""),
            SignalEvidence(key: "repeatsEveryOther", about: .processing, strength: 1, detail: ""),
            SignalEvidence(key: "narrowSound", about: .source, strength: 1, detail: ""),
        ]
        let conclusions = SignalInferenceRules.conclusions(from: evidence)
        #expect(conclusions.contains { $0.category == "Digital SD" })
        #expect(conclusions.contains { $0.category == "Early Web / Low-Bitrate Digital" })
        let unknown = try? #require(conclusions.first { $0.category == "Unknown" })
        #expect(unknown != nil)
        #expect(unknown?.supportedBy.isEmpty == false)
    }

    @Test func aRampRunsEitherWay() {
        #expect(SignalEvidenceRules.ramp(0.5, from: 0, to: 1) == 0.5)
        #expect(SignalEvidenceRules.ramp(0.3, from: 0.42, to: 0.24) > 0.6)
        #expect(SignalEvidenceRules.ramp(0.5, from: 0.42, to: 0.24) == 0)
        #expect(SignalEvidenceRules.ramp(9, from: 0, to: 1) == 1)
    }
}

@Suite struct SignalConclusionStorageTests {

    private func library() async throws -> (LibraryDatabase, MediaItem) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Signal")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("conclusions"))
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        return (library, item)
    }

    @Test func conclusionsAreStoredWithTheEvidenceTheyRestOn() async throws {
        let (library, item) = try await library()
        var findings = SignalFindings()
        findings.declare("container.writingApplication", "HandBrake 1.7.0")
        findings.measure("geometry.pillarboxed", 1)
        findings.measure("geometry.pillarboxFraction", 0.25)
        findings.measure("geometry.activeAspectRatio", 1.333)
        try library.recordSignalStage(itemID: item.id, stage: "declared", version: 1, findings: findings)
        try MediaSignalJob.drawConclusions(for: item.id, in: library)

        let stored = try library.signalInferences(itemID: item.id)
        let bars = try #require(stored.first { $0.inference.category == "Bars encoded into the picture" })
        #expect(bars.evidence.map(\.key) == ["pillarboxed"])
        #expect(bars.evidence[0].detail.contains("1.33:1"))
        #expect(stored.contains { $0.inference.category == "Re-encoded by a transcoder" })
        #expect(try library.signalEvidence(itemID: item.id).count >= 2)

        // Drawing again replaces; nothing is left behind from before.
        try MediaSignalJob.drawConclusions(for: item.id, in: library)
        #expect(try library.signalInferences(itemID: item.id).count == stored.count)
    }

    @Test func newerRulesAndNewerFindingsBothCallForRedrawing() async throws {
        let (library, item) = try await library()
        try library.recordSignalStage(itemID: item.id, stage: "declared", version: 1, findings: SignalFindings())
        #expect(try library.itemsNeedingSignalConclusions(rulesVersion: 1) == [item.id])

        try library.replaceSignalConclusions(itemID: item.id, evidence: [], conclusions: [], rulesVersion: 1)
        #expect(try library.itemsNeedingSignalConclusions(rulesVersion: 1).isEmpty)
        #expect(try library.itemsNeedingSignalConclusions(rulesVersion: 2) == [item.id])

        // A stage that finishes later than the conclusions outdates them.
        try await library.writer.write { db in
            try SignalStageState(
                mediaItemID: item.id, stage: "audioSignal", version: 1,
                completedAt: Date().addingTimeInterval(60)
            ).upsert(db)
        }
        #expect(try library.itemsNeedingSignalConclusions(rulesVersion: 1) == [item.id])
    }

    @Test func resettingFindingsTakesConclusionsWithThem() async throws {
        let (library, item) = try await library()
        var findings = SignalFindings()
        findings.measure("colour.monochrome", 1)
        try library.recordSignalStage(itemID: item.id, stage: "pictureStills", version: 1, findings: findings)
        try MediaSignalJob.drawConclusions(for: item.id, in: library)
        #expect(!(try library.signalEvidence(itemID: item.id)).isEmpty)
        try library.resetSignalFindings()
        #expect(try library.signalEvidence(itemID: item.id).isEmpty)
        #expect(try library.signalInferences(itemID: item.id).isEmpty)
    }
}
