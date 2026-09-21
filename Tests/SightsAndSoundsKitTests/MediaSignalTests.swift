import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The decoder configuration records are read by offset, so the offsets
/// are what is tested: records built here byte by byte, to the layout in
/// ISO/IEC 14496-15.
@Suite struct CodecConfigurationTests {

    /// An `avcC` with one SPS and one PPS of the given lengths.
    private func avcRecord(profile: UInt8, constraints: UInt8 = 0, level: UInt8, tail: [UInt8] = []) -> Data {
        var bytes: [UInt8] = [1, profile, constraints, level, 0xFF]
        bytes += [0xE1, 0x00, 0x03, 0x67, 0x64, 0x00]  // one SPS, 3 bytes
        bytes += [0x01, 0x00, 0x02, 0x68, 0xEE]  // one PPS, 2 bytes
        return Data(bytes + tail)
    }

    @Test func highProfileReadsChromaAndDepthFromBehindTheParameterSets() {
        // 0xFC | 1 = 4:2:0; 0xF8 | 2 = 10-bit luma.
        let record = avcRecord(profile: 110, level: 41, tail: [0xFD, 0xFA, 0xFA, 0x00])
        let configuration = CodecConfiguration.avc(record)
        #expect(configuration?.profile == "High 10")
        #expect(configuration?.level == "4.1")
        #expect(configuration?.chromaSubsampling == "4:2:0")
        #expect(configuration?.bitDepth == 10)
    }

    @Test func mainProfileIsEightBitFourTwoZeroByDefinition() {
        let configuration = CodecConfiguration.avc(avcRecord(profile: 77, level: 30))
        #expect(configuration?.profile == "Main")
        #expect(configuration?.level == "3")
        #expect(configuration?.bitDepth == 8)
        #expect(configuration?.chromaSubsampling == "4:2:0")
    }

    @Test func constrainedBaselineAndLevelOneB() {
        let configuration = CodecConfiguration.avc(avcRecord(profile: 66, constraints: 0x50, level: 11))
        #expect(configuration?.profile == "Constrained Baseline")
        #expect(configuration?.level == "1b")
    }

    @Test func aTruncatedHighProfileRecordStillNamesItsProfile() {
        var record = avcRecord(profile: 100, level: 40)
        record.removeLast(3)
        let configuration = CodecConfiguration.avc(record)
        #expect(configuration?.profile == "High")
        #expect(configuration?.bitDepth == nil)
    }

    @Test func hevcMainTenHighTier() {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = 0x20 | 2  // high tier, Main 10
        bytes[12] = 153  // level 5.1
        bytes[16] = 0xFC | 1  // 4:2:0
        bytes[17] = 0xF8 | 2  // 10-bit
        let configuration = CodecConfiguration.hevc(Data(bytes))
        #expect(configuration?.profile == "Main 10")
        #expect(configuration?.tier == "High")
        #expect(configuration?.level == "5.1")
        #expect(configuration?.bitDepth == 10)
        #expect(configuration?.chromaSubsampling == "4:2:0")
    }

    @Test func garbageIsNotAConfiguration() {
        #expect(CodecConfiguration.avc(Data([9, 9])) == nil)
        #expect(CodecConfiguration.hevc(Data([0, 1, 2])) == nil)
    }

    @Test func encoderSettingsAreFoundInsideTheFirstSample() {
        var sample = Data([0, 0, 0, 40, 6, 5, 0xFF])
        sample += Data("x264 - core 164 - H.264/MPEG-4 AVC codec - options: crf=20.0 keyint=240".utf8)
        sample += Data([0, 0x80, 0, 0, 1, 0x65])
        let settings = CodecConfiguration.encoderSettings(inFirstSample: sample)
        #expect(settings?.hasPrefix("x264 - core 164") == true)
        #expect(settings?.hasSuffix("keyint=240") == true)
        #expect(CodecConfiguration.encoderSettings(inFirstSample: Data([1, 2, 3])) == nil)
    }

    @Test func fileTypeBrandsComeFromTheOpeningBox() {
        var head = Data([0, 0, 0, 24])
        head += Data("ftypisom".utf8) + Data([0, 0, 2, 0]) + Data("isomavc1".utf8)
        head += Data("moov and the rest".utf8)
        let brands = DeclaredStage.fileTypeBrands(inHead: head)
        #expect(brands?.major == "isom")
        #expect(brands?.compatible == ["isom", "avc1"])
        #expect(DeclaredStage.fileTypeBrands(inHead: Data("RIFF....WAVEfmt ....".utf8)) == nil)
    }
}

@Suite struct FrameTimingTests {

    /// `count` frames at `interval`, a keyframe every `gop`, stored in
    /// presentation order.
    private func frames(
        _ count: Int, interval: Double, gop: Int = 12, bytes: (Int) -> Int = { _ in 1000 }
    ) -> [FrameSample] {
        (0..<count).map {
            FrameSample(
                presentationSeconds: Double($0) * interval, decodeSeconds: Double($0) * interval,
                byteCount: bytes($0), isKeyframe: $0 % gop == 0)
        }
    }

    @Test func constantRateFilmFile() {
        let findings = FrameTiming.measure(
            frames(2400, interval: 1001.0 / 24000, gop: 48), encodedWidth: 100, encodedHeight: 100)
        #expect(findings.value("timing.frameCount") == 2400)
        #expect(findings.value("timing.constantFrameRate") == 1)
        #expect(abs(findings.value("timing.averageFrameRate")! - 23.976) < 0.001)
        #expect(abs(findings.value("timing.rateFamily")! - 24000.0 / 1001) < 1e-9)
        #expect(abs(findings.value("timing.keyframeIntervalFramesTypical")! - 48) < 1e-6)
        #expect(findings.value("timing.framesReordered") == 0)
        // 1000 bytes a frame at 23.976 fps, over 10 000 pixels.
        #expect(abs(findings.value("timing.bitsPerPixel")! - 0.8) < 1e-6)
    }

    @Test func twentyFourIsNotMistakenForItsNtscNeighbour() {
        let findings = FrameTiming.measure(frames(2400, interval: 1.0 / 24))
        #expect(findings.value("timing.rateFamily") == 24)
    }

    @Test func millisecondTimestampsAreStillConstantRate() {
        // 29.97 fps the way a millisecond timescale stores it: 33, 33, 34…
        let samples = (0..<3000).map { index -> FrameSample in
            let time = (Double(index) * 1001.0 / 30000 * 1000).rounded() / 1000
            return FrameSample(presentationSeconds: time, decodeSeconds: time, byteCount: 500, isKeyframe: index % 30 == 0)
        }
        let findings = FrameTiming.measure(samples)
        #expect(findings.value("timing.constantFrameRate") == 1)
        #expect(abs(findings.value("timing.rateFamily")! - 30000.0 / 1001) < 1e-9)
    }

    @Test func aPhoneStyleVariableRateFileIsCalledVariable() {
        var time = 0.0
        let samples = (0..<600).map { index -> FrameSample in
            defer { time += index.isMultiple(of: 3) ? 1.0 / 30 : 1.0 / 24 }
            return FrameSample(presentationSeconds: time, decodeSeconds: time, byteCount: 500, isKeyframe: index % 30 == 0)
        }
        let findings = FrameTiming.measure(samples)
        #expect(findings.value("timing.constantFrameRate") == 0)
        #expect(findings.value("timing.regularIntervalFraction")! < 0.9)
    }

    @Test func framesStoredOutOfDisplayOrderMeanReordering() {
        // Decode order I P B B: shown at 0, 3, 1, 2.
        let shown = [0.0, 3, 1, 2, 4, 7, 5, 6].map { $0 / 25 }
        let samples = shown.enumerated().map {
            FrameSample(presentationSeconds: $1, decodeSeconds: Double($0) / 25, byteCount: 100, isKeyframe: $0 % 4 == 0)
        }
        #expect(FrameTiming.measure(samples).value("timing.framesReordered") == 1)
    }

    @Test func bitrateVariationSeparatesFlatFromBursty() {
        let flat = FrameTiming.measure(frames(300, interval: 1.0 / 30))
        let bursty = FrameTiming.measure(
            frames(300, interval: 1.0 / 30) { ($0 / 30).isMultiple(of: 2) ? 4000 : 200 })
        #expect(flat.value("timing.bitrateVariation")! < 0.01)
        #expect(bursty.value("timing.bitrateVariation")! > 0.5)
    }

    @Test func oneFrameMeasuresNothing() {
        #expect(FrameTiming.measure(frames(1, interval: 1)).measured.isEmpty)
    }
}

/// The stages against a real file. The demo factory's clip is 320x180
/// H.264 at 12 frames a second, written by AVFoundation.
@Suite struct MediaSignalStageTests {

    private func clip(seconds: Double = 3) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-signal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clip.mp4")
        try await DemoMediaFactory.writeVideo(to: url, seconds: seconds)
        return url
    }

    @Test func declaredStageReadsTheEncodeTheFactoryWrote() async throws {
        let url = try await clip()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let findings = try await DeclaredStage().examine(SignalStageInput(url: url, kind: .video))

        #expect(findings.declared["video.codecTag"] == "avc1")
        #expect(findings.declared["video.encodedWidth"] == "320")
        #expect(findings.declared["video.encodedHeight"] == "180")
        #expect(findings.declared["video.bitDepth"] == "8")
        #expect(findings.declared["video.chromaSubsampling"] == "4:2:0")
        #expect(findings.declared["video.profile"] != nil)
        #expect(findings.declared["video.level"] != nil)
        #expect(findings.declared["container.majorBrand"] != nil)
        #expect(findings.declared["container.videoTrackCount"] == "1")
        #expect(findings.declared["video.rotationDegrees"] == "0")
        #expect(findings.value("container.overallBitrate")! > 0)
    }

    @Test func frameTimingStageCountsTheFramesThatWereWritten() async throws {
        let url = try await clip(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let findings = try await FrameTimingStage().examine(SignalStageInput(url: url, kind: .video))

        #expect(findings.value("timing.frameCount") == 36)
        #expect(abs(findings.value("timing.averageFrameRate")! - 12) < 0.01)
        #expect(findings.value("timing.constantFrameRate") == 1)
        #expect(findings.value("timing.keyframeCount")! >= 1)
        #expect(findings.value("timing.videoBitrate")! > 0)
    }

    @Test func aFileThatIsNotMediaIsAStageFailure() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-signal-\(UUID().uuidString).mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: SignalStageError.self) {
            _ = try await DeclaredStage().examine(SignalStageInput(url: url, kind: .video))
        }
    }

    @Test func ffprobeAndMediaInfoOutputIsFlattenedUnderTheToolsName() {
        var findings = SignalFindings()
        ProbeToolsStage.readFfprobe(Data("""
            {"format": {"format_name": "mov,mp4", "tags": {"encoder": "Lavf60.3.100"}},
             "streams": [
               {"codec_type": "video", "codec_name": "mjpeg", "disposition": {"attached_pic": 1}},
               {"codec_type": "video", "codec_name": "h264", "field_order": "progressive",
                "has_b_frames": 2, "side_data_list": [{"side_data_type": "Mastering display metadata"}]},
               {"codec_type": "audio", "codec_name": "aac", "channel_layout": "stereo"},
               {"codec_type": "audio", "codec_name": "ac3"}]}
            """.utf8), into: &findings)
        #expect(findings.declared["ffprobe.format.encoder"] == "Lavf60.3.100")
        #expect(findings.declared["ffprobe.video.codec_name"] == "h264")  // not the cover art
        #expect(findings.declared["ffprobe.video.has_b_frames"] == "2")
        #expect(findings.declared["ffprobe.video.sideData.Mastering display metadata"] == "present")
        #expect(findings.declared["ffprobe.audio.codec_name"] == "aac")  // the first audio stream

        ProbeToolsStage.readMediaInfo(Data("""
            {"media": {"track": [
               {"@type": "General", "Format": "MPEG-4", "Encoded_Application": "HandBrake 1.7.0"},
               {"@type": "Video", "BitRate_Mode": "VBR", "FrameRate_Mode": "CFR", "ScanType": "Progressive"}]}}
            """.utf8), into: &findings)
        #expect(findings.declared["mediainfo.general.Encoded_Application"] == "HandBrake 1.7.0")
        #expect(findings.declared["mediainfo.video.FrameRate_Mode"] == "CFR")
    }
}

/// The sweep's bookkeeping: what counts as missing, and what a re-run,
/// a failure, a version bump and a retry each do to it.
@Suite struct MediaSignalSweepTests {

    struct StubStage: SignalStage {
        var name = "stub"
        var version = 1
        var kinds: Set<MediaKind> = [.video]
        var result: Result<SignalFindings, SignalStageError> = .success(SignalFindings())

        func examine(_ file: SignalStageInput) async throws -> SignalFindings { try result.get() }
    }

    private func library() async throws -> (LibraryDatabase, video: MediaItem, audio: MediaItem, segment: MediaItem) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Signal")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("signal"))
        let video = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let audio = MediaItem(sourceID: source.id, kind: .audio, relativePath: "b.m4a", needsReview: false)
        var clip = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        clip.parentMediaItemID = video.id
        clip.clipStartSeconds = 1
        clip.clipEndSeconds = 2
        let segment = clip
        try await library.writer.write { db in
            try source.insert(db)
            try video.insert(db)
            try audio.insert(db)
            try segment.insert(db)
        }
        return (library, video, audio, segment)
    }

    @Test func onlyWholeFilesOfAStagesKindAreMissing() async throws {
        let (library, video, _, _) = try await library()
        let work = try library.itemsNeedingSignalStages([StubStage()])
        #expect(work.map(\.item.id) == [video.id])  // not the audio file, not the segment
        #expect(work.first?.stages == ["stub"])
        #expect(try library.signalStatus([StubStage()]) == SweepStatus(missing: 1, failed: 0))
    }

    @Test func aRecordedStageIsDoneAndItsRerunReplacesItsRows() async throws {
        let (library, video, _, _) = try await library()
        var first = SignalFindings()
        first.declare("video.codecTag", "avc1")
        first.declare("video.stale", "yes")
        first.measure("timing.frameCount", 10)
        try library.recordSignalStage(itemID: video.id, stage: "stub", version: 1, findings: first)
        #expect(try library.itemsNeedingSignalStages([StubStage()]).isEmpty)

        var second = SignalFindings()
        second.declare("video.codecTag", "hvc1")
        second.measure("timing.frameCount", 20)
        try library.recordSignalStage(itemID: video.id, stage: "stub", version: 1, findings: second)
        #expect(try library.signalDeclared(itemID: video.id) == ["video.codecTag": "hvc1"])
        #expect(try library.signalMeasurements(itemID: video.id).map(\.value) == [20])
    }

    @Test func oneStagesRerunLeavesAnotherStagesRowsAlone() async throws {
        let (library, video, _, _) = try await library()
        var declared = SignalFindings()
        declared.declare("video.codecTag", "avc1")
        try library.recordSignalStage(itemID: video.id, stage: "declared", version: 1, findings: declared)
        var timing = SignalFindings()
        timing.measure("timing.frameCount", 5)
        try library.recordSignalStage(itemID: video.id, stage: "frameTiming", version: 1, findings: timing)
        try library.recordSignalStage(itemID: video.id, stage: "frameTiming", version: 1, findings: SignalFindings())
        #expect(try library.signalDeclared(itemID: video.id) == ["video.codecTag": "avc1"])
        #expect(try library.signalMeasurements(itemID: video.id).isEmpty)
    }

    @Test func aNewerStageVersionMakesTheItemMissingAgain() async throws {
        let (library, video, _, _) = try await library()
        try library.recordSignalStage(itemID: video.id, stage: "stub", version: 1, findings: SignalFindings())
        var newer = StubStage()
        newer.version = 2
        #expect(try library.itemsNeedingSignalStages([newer]).map(\.item.id) == [video.id])
    }

    @Test func aFailureIsAMarkerUntilItIsRetried() async throws {
        let (library, video, _, _) = try await library()
        try library.recordSignalStage(
            itemID: video.id, stage: "stub", version: 1, findings: SignalFindings(), failure: "unreadable")
        #expect(try library.signalStatus([StubStage()]) == SweepStatus(missing: 0, failed: 1))
        try library.retrySignalFailures()
        #expect(try library.signalStatus([StubStage()]) == SweepStatus(missing: 1, failed: 0))
    }

    @Test func deletingAnItemTakesItsFindingsWithIt() async throws {
        let (library, video, _, _) = try await library()
        var findings = SignalFindings()
        findings.declare("video.codecTag", "avc1")
        findings.measure("timing.frameCount", 10)
        try library.recordSignalStage(itemID: video.id, stage: "stub", version: 1, findings: findings)
        try await library.writer.write { db in
            try db.execute(sql: "DELETE FROM mediaItem WHERE parentMediaItemID = ?", arguments: [video.id])
            try db.execute(sql: "DELETE FROM mediaItem WHERE id = ?", arguments: [video.id])
        }
        let left = try await library.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM mediaSignalDeclared) + (SELECT COUNT(*) FROM mediaSignalMeasurement)
                     + (SELECT COUNT(*) FROM mediaSignalStage)
                """)
        }
        #expect(left == 0)
    }
}

@Suite struct MediaSignalJobTests {

    @Test func theJobExaminesAFileAndAFailingStageDoesNotStopTheOthers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-signal-job-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("clip.mp4"), seconds: 2)

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Signal")
        let source = Source(name: "S", rootPath: root.path)
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "clip.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }

        var broken = MediaSignalSweepTests.StubStage()
        broken.name = "broken"
        broken.result = .failure(SignalStageError("synthetic failure"))
        let stages: [any SignalStage] = [DeclaredStage(), broken, FrameTimingStage()]

        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { _ in })
        try await MediaSignalJob(stages: stages).run(context)

        #expect(try library.signalDeclared(itemID: item.id)["video.codecTag"] == "avc1")
        #expect(try library.signalMeasurements(itemID: item.id).contains { $0.key == "timing.frameCount" && $0.value == 24 })
        let states = try library.signalStageStates(itemID: item.id)
        #expect(states.map(\.stage) == ["broken", "conclusions", "declared", "frameTiming"])
        #expect(states.first { $0.stage == "broken" }?.failureMessage == "synthetic failure")
        #expect(try library.itemsNeedingSignalStages(stages).isEmpty)
    }

    @Test func anOfflineSourceLeavesNoMarker() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Signal")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("signal-offline"))
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let context = JobContext(
            library: library, jobID: UUID(), progressHandler: { _, _ in },
            cancellationCheck: { false }, summaryHandler: { _ in })
        try await MediaSignalJob(stages: [DeclaredStage()]).run(context)
        #expect(try library.signalStageStates(itemID: item.id).isEmpty)
    }
}
