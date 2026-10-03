import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What this app did to a file is history Media Signal can read. Every
/// ffmpeg path here stamps the file "Lavf…", which the origin rules took as
/// proof of a transcode — so a file only copied here read as re-encoded.
@Suite struct FileRewriteHistoryTests {
    private func lavfFacts(rewrites: [FileRewrite]) -> SignalFacts {
        SignalFacts(declared: ["ffprobe.format.encoder": "Lavf61.7.100"], measurements: [], rewrites: rewrites)
    }

    private func has(_ key: String, in evidence: [SignalEvidence]) -> Bool { evidence.contains { $0.key == key } }

    @Test func anFfmpegStampWithNoHistoryIsATranscode() {
        let evidence = SignalEvidenceRules.evidence(from: lavfFacts(rewrites: []))
        #expect(has("transcoderNamed", in: evidence))
        #expect(!has("rewrittenHere", in: evidence))
    }

    @Test func anFfmpegStampAfterACopyMadeHereIsOurs() {
        let copy = FileRewrite(mediaItemID: UUID(), operation: .tagWrite, tool: "ffmpeg", reencoded: false)
        let evidence = SignalEvidenceRules.evidence(from: lavfFacts(rewrites: [copy]))
        #expect(!has("transcoderNamed", in: evidence), "our own stamp was read as a transcode")
        #expect(has("rewrittenHere", in: evidence))
        #expect(!has("reencodedHere", in: evidence))
    }

    @Test func aReencodeHereIsSaidAsSuch() {
        let salvage = FileRewrite(
            mediaItemID: UUID(), operation: .repair, tool: "ffmpeg", reencoded: true, note: "Salvage by re-encoding")
        let evidence = SignalEvidenceRules.evidence(from: lavfFacts(rewrites: [salvage]))
        #expect(has("reencodedHere", in: evidence))
        #expect(evidence.first { $0.key == "reencodedHere" }?.detail.contains("Salvage") == true)
        let (_, conclusions) = SignalInferenceRules.conclude(lavfFacts(rewrites: [salvage]))
        #expect(conclusions.contains { $0.category == "Re-encoded here" && $0.confidence >= 0.99 })
    }

    @Test func aStampThatIsNotFfmpegsStaysATranscodeWhateverWeDid() {
        var facts = lavfFacts(rewrites: [
            FileRewrite(mediaItemID: UUID(), operation: .remux, tool: "AVFoundation", reencoded: false),
        ])
        facts.declared["ffprobe.format.encoder"] = "HandBrake 1.7.0"
        let evidence = SignalEvidenceRules.evidence(from: facts)
        #expect(has("transcoderNamed", in: evidence), "HandBrake's stamp is not ours")
        #expect(has("rewrittenHere", in: evidence))
    }

    @Test func anAvFoundationRemuxDoesNotExplainAnFfmpegStamp() {
        let remux = FileRewrite(mediaItemID: UUID(), operation: .remux, tool: "AVFoundation", reencoded: false)
        let evidence = SignalEvidenceRules.evidence(from: lavfFacts(rewrites: [remux]))
        #expect(has("transcoderNamed", in: evidence), "only an ffmpeg rewrite leaves the Lavf stamp")
    }

    @Test func tagWritesMadeBeforeTheHistoryExistedCountAsHistory() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "History")
        let source = Source(name: "S", rootPath: "/tmp/sas-history-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mkv", needsReview: false)
        let run = TagWriteRun(scopeDescription: "then", totalFiles: 1)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try run.insert(db)
            try TagWriteRunFile(
                tagWriteRunID: run.id, mediaItemID: item.id, filePath: "a.mkv",
                status: .written, error: nil, usedRemuxFallback: true).insert(db)
            try TagWriteRunFile(
                tagWriteRunID: run.id, mediaItemID: item.id, filePath: "a.mkv",
                status: .failed, error: "no", usedRemuxFallback: true).insert(db)
        }
        let history = try library.rewrites(of: item.id)
        #expect(history.count == 1, "a failed write is not a rewrite")
        #expect(history.first?.operation == .tagWrite && history.first?.tool == "ffmpeg")
        #expect(try library.signalFacts(itemID: item.id).rewrites.count == 1)
    }

    @Test func aRecordedRewriteIsNewestFirstAndSummarised() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "History")
        let source = Source(name: "S", rootPath: "/tmp/sas-history-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try FileRewrite(
                mediaItemID: item.id, happenedAt: Date(timeIntervalSince1970: 1_000), operation: .remux,
                tool: "AVFoundation", reencoded: false, note: "optimize").insert(db)
            try FileRewrite(
                mediaItemID: item.id, happenedAt: Date(timeIntervalSince1970: 2_000), operation: .repair,
                tool: "ffmpeg", reencoded: true, note: "Salvage").insert(db)
        }
        let history = try library.rewrites(of: item.id)
        #expect(history.map(\.operation) == [.repair, .remux])
        #expect(history[0].summary.hasPrefix("repaired · "))
        #expect(history[0].summary.hasSuffix("ffmpeg, re-encoded (Salvage)"))
        #expect(history[1].summary.hasSuffix("AVFoundation, streams copied (optimize)"))
    }
}
