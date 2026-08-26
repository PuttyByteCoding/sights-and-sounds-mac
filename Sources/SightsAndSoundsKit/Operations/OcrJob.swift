import AVFoundation
import Foundation
import GRDB
import Vision

/// One recognized line of on-screen text — search results can jump
/// straight to `timeSeconds`.
public struct OcrTextLine: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ocrTextLine"

    public var id: UUID
    public var mediaItemID: UUID
    public var timeSeconds: Double
    public var text: String

    public init(id: UUID = UUID(), mediaItemID: UUID, timeSeconds: Double, text: String) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.timeSeconds = timeSeconds
        self.text = text
    }
}

/// Full-item OCR via Vision — resumable, ported shape: frames sampled on
/// an interval, one row per frame that produced text, and the scan's
/// reach tracked in `ocrProgress` so a resume continues past stretches
/// that found nothing. Each run scans a bounded budget; run it again to
/// scan more.
public struct OcrJob: Job {
    public static let kind = "operations.ocr"

    public static var sampleIntervalSeconds: Double {
        max(1, AppSettingsStore.shared.current.ocrSampleIntervalSeconds)
    }
    public static var budgetSecondsPerRun: Double {
        max(30, AppSettingsStore.shared.current.ocrBudgetSecondsPerRun)
    }

    public struct Payload: Codable, Sendable {
        public var itemID: UUID
        public init(itemID: UUID) { self.itemID = itemID }
    }

    let payload: Payload
    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        guard let payload, let decoded = try? JSONDecoder().decode(Payload.self, from: payload)
        else { throw UnknownJobKindError(kind: "operations.ocr: missing payload") }
        self.payload = decoded
        fileAccess = LiveFileAccess()
    }

    public static func enqueue(on runner: JobRunner, itemID: UUID) async throws -> JobRecord {
        try await runner.enqueue(
            OcrJob.self, payload: JSONEncoder().encode(Payload(itemID: itemID)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        guard let item = try await library.writer.read({ try MediaItem.fetchOne($0, key: payload.itemID) })
        else { throw ClipError.itemNotFound }
        guard item.kind == .video else {
            throw AVExport.ExportFailure(message: "OCR reads video frames — audio items have none")
        }
        guard let duration = item.durationSeconds, duration > 0 else {
            throw AVExport.ExportFailure(message: "unknown duration — probe the item first")
        }
        guard let fileURL = try library.resolvedFileURL(for: item, fileAccess: fileAccess),
              fileAccess.isReachable(fileURL)
        else { throw MoveError.sourceUnavailable }

        let scannedThrough = try await library.writer.read { db in
            try OcrProgress.fetchOne(db, key: item.id)?.scannedThroughSeconds
        } ?? 0
        guard scannedThrough < duration else {
            await context.setSummary("already fully scanned")
            return
        }

        let runEnd = min(duration, scannedThrough + Self.budgetSecondsPerRun)
        let times = stride(
            from: scannedThrough, to: runEnd, by: Self.sampleIntervalSeconds
        ).map { $0 }
        guard !times.isEmpty else {
            await context.setSummary("already fully scanned")
            return
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var linesFound = 0
        await context.reportProgress(current: 0, total: times.count)

        for (index, seconds) in times.enumerated() {
            try await context.checkCancellation()
            let text = await Self.recognizeText(generator: generator, at: seconds)
            if let text, !text.isEmpty {
                let line = OcrTextLine(mediaItemID: item.id, timeSeconds: seconds, text: text)
                try await library.writer.write { try line.insert($0) }
                linesFound += 1
            }
            // Reach advances whether or not the frame had text — ported.
            let reached = min(duration, seconds + Self.sampleIntervalSeconds)
            try await library.writer.write { db in
                try OcrProgress(mediaItemID: item.id, scannedThroughSeconds: reached).upsert(db)
            }
            await context.reportProgress(current: index + 1, total: times.count)
        }

        let remaining = duration - runEnd
        var summary = String(
            format: "scanned %.0fs–%.0fs: %d text lines", scannedThrough, runEnd, linesFound)
        if remaining > 1 { summary += String(format: " (%.0fs left — run again)", remaining) }
        await context.setSummary(summary)
    }

    /// One frame → recognized text (lines joined), or nil. The generator
    /// stays in this isolation region; Vision runs on the CGImage inside
    /// the continuation's callback.
    static func recognizeText(generator: AVAssetImageGenerator, at seconds: Double) async -> String? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, cgImage, _, result, _ in
                guard result == .succeeded, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: cgImage)
                guard (try? handler.perform([request])) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }
}
