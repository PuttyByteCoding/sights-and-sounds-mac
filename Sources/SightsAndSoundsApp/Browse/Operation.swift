import SwiftUI
import SightsAndSoundsKit

/// The operations, with the names the grid's context menu already uses.
///
/// One list, used by the window and by the menu, so the two cannot come
/// to call the same job different things.
enum Operation: String, CaseIterable {
    case optimize, repair, encode, clipExport, blockRemoval, ocr, join, writeTags

    /// Verbatim from the context menu.
    var title: String {
        switch self {
        case .optimize: "Optimize (Faststart)"
        case .repair: "Repair Container"
        case .encode: "Encode a Copy"
        case .clipExport: "Export Clip to File"
        case .blockRemoval: "Export Copy Without Hidden Blocks"
        case .ocr: "Scan On-Screen Text (OCR)"
        case .join: "Join Folder's Files"
        case .writeTags: "Write Tags to File"
        }
    }

    /// Four of these copy streams untouched, OCR writes no file at all,
    /// and only Encode loses a generation. That distinction decides how
    /// freely each can be used, so it is a chip on the row.
    enum Kind {
        case streamCopy, reEncode, readsOnly, writesTags

        var label: String {
            switch self {
            case .streamCopy: "stream copy"
            case .reEncode: "re-encode"
            case .readsOnly: "reads only"
            case .writesTags: "writes tags"
            }
        }

        var color: Color {
            switch self {
            case .streamCopy: Theme.Status.green
            case .reEncode: Theme.Accent.amber
            case .readsOnly: Theme.Status.blue
            case .writesTags: Theme.Status.mauve
            }
        }
    }

    var kind: Kind {
        switch self {
        case .encode: .reEncode
        case .ocr: .readsOnly
        case .writeTags: .writesTags
        default: .streamCopy
        }
    }

    var produces: String {
        switch self {
        case .optimize: "A container with the index up front"
        case .repair: "A rebuilt container beside the original"
        case .encode: "A new file in the chosen codec"
        case .clipExport: "A standalone file for an embedded clip"
        case .blockRemoval: "An edited copy without the hidden ranges"
        case .ocr: "Searchable text stored against the item"
        case .join: "One file from several parts"
        case .writeTags: "Tags written into the file's own metadata"
        }
    }

    var blurb: String {
        switch self {
        case .encode:
            "Re-encode into a fresh file beside the original. The original is not touched, not replaced, and not deleted — this only ever adds."
        case .optimize, .repair:
            "Rewrite the container without touching a single frame. Optimize moves the index to the front so a file starts playing instantly; Repair rebuilds a container that will not open."
        case .join:
            "Concatenate several files into one. Stream copy, so it is exact and fast — and it refuses outright when the parts do not actually match."
        case .clipExport:
            "Turn an embedded clip into a standalone file. Stream-copied, never re-encoded — and the clip is not deleted from its parent."
        case .blockRemoval:
            "Cut the hidden ranges out into an edited copy. The player already skips these live, so what you have been hearing is what the edit keeps."
        case .ocr:
            "Read the text visible in each frame with Vision and store it against the item. The only operation here that writes no file — it adds searchable text and nothing else."
        case .writeTags:
            "Write this library's tags into the files themselves, so the metadata travels with the media."
        }
    }

    /// Three specific bullets rather than a general reassurance: nothing
    /// is modified in place, so there is no undo to design.
    var guarantees: [String] {
        switch self {
        case .encode:
            [
                "The original file stays exactly where it is.",
                "The new file is added beside it and imported as its own item.",
                "Re-encoding loses a generation of quality — the only operation here that does.",
            ]
        case .optimize, .repair:
            [
                "Byte-identical streams — no quality change is possible.",
                "The result is verified before the original is moved aside.",
                "The original is archived under _Replaced and named in the summary.",
            ]
        case .join:
            [
                "The parts are left untouched on disk.",
                "Stream copy — the joined file is exact.",
                "A mismatch is refused before anything is written.",
            ]
        case .clipExport:
            [
                "The clip row is kept, marked exported, not deleted.",
                "Stream-copied from the parent — no re-encode.",
                "The parent file is not modified.",
            ]
        case .blockRemoval:
            [
                "The original file is not modified.",
                "The edit keeps exactly what the player already skips past.",
                "The copy is added beside the original.",
            ]
        case .ocr:
            [
                "Vision runs locally; nothing leaves the machine.",
                "The media file is opened read-only and never written.",
                "Rescanning replaces the previous result for that item, so tightening a setting and running again is safe.",
            ]
        case .writeTags:
            [
                "The file's existing tags are snapshotted first, and restorable.",
                "Only categories with write-back enabled are written.",
                "The media streams are untouched.",
            ]
        }
    }

    var verb: String {
        switch self {
        case .ocr: "Scan"
        case .join: "Join"
        case .writeTags: "Write"
        default: "Run on"
        }
    }

    // MARK: - Requirements

    /// What this operation needs that the selection does not have —
    /// shown where the description goes, so an unavailable row explains
    /// itself instead of vanishing.
    func unmetRequirement(for items: [MediaItem]) -> String? {
        let accepted = items.filter(accepts)
        switch self {
        case .join:
            return accepted.count >= 2 ? nil : "needs at least 2 items selected"
        case .clipExport:
            return accepted.isEmpty ? "needs an embedded clip that is not exported yet" : nil
        case .blockRemoval:
            return accepted.isEmpty ? "needs an item with hidden ranges" : nil
        case .ocr:
            return accepted.isEmpty ? "needs a video item" : nil
        default:
            return accepted.isEmpty ? "unavailable for this selection" : nil
        }
    }

    func blockedLabel(for items: [MediaItem]) -> String {
        unmetRequirement(for: items) ?? "Nothing selected"
    }

    /// Which rows this operation can act on. A clip is a range, not a
    /// file, so the container operations skip child rows entirely.
    func accepts(_ item: MediaItem) -> Bool {
        switch self {
        case .optimize, .repair, .encode, .join, .writeTags:
            item.parentMediaItemID == nil
        case .clipExport:
            item.parentMediaItemID != nil && !item.isExportedClip
        case .blockRemoval:
            item.parentMediaItemID == nil
        case .ocr:
            item.kind == .video
        }
    }

    func output(for item: MediaItem) -> String {
        let base = (item.fileName as NSString).deletingPathExtension
        switch self {
        case .optimize, .repair: return "\(base).mp4"
        case .encode: return "\(base) (encoded).mp4"
        case .clipExport: return "\(base) (clip).mp4"
        case .blockRemoval: return "\(base) (edited).mp4"
        case .join: return "\(base) (joined).mp4"
        case .ocr: return "text lines on this item"
        case .writeTags: return "tags written in place"
        }
    }

    func summary(count: Int) -> String {
        switch self {
        case .ocr: "Reads \(count) items and writes no files."
        case .join: "Writes one file from \(count) parts; the parts stay where they are."
        case .writeTags: "Writes tags into \(count) files; the streams are untouched."
        default: "Writes \(count) new files beside the originals."
        }
    }

    // MARK: - Cost and command

    func estimate(
        for items: [MediaItem], preset: EncodeJob.Preset,
        ocr: OcrSettings, interval: Double
    ) -> OperationEstimate {
        switch self {
        case .optimize, .repair:
            return OperationEstimates.streamCopy(sizes: items.map(\.fileSize))
        case .encode:
            return OperationEstimates.encode(
                durations: items.compactMap(\.durationSeconds),
                targetBitsPerSecond: preset.estimatedBitsPerSecond)
        case .join:
            return OperationEstimates.join(sizes: items.map(\.fileSize))
        case .clipExport:
            return items.reduce(into: OperationEstimate(timeLabel: "of copying")) { total, item in
                let clip = OperationEstimates.clipExport(
                    clipSeconds: (item.clipEndSeconds ?? 0) - (item.clipStartSeconds ?? 0),
                    parentSeconds: item.durationSeconds ?? 0,
                    parentBytes: item.fileSize)
                total.filesWritten += clip.filesWritten
                total.bytesAdded += clip.bytesAdded
                total.seconds += clip.seconds
            }
        case .blockRemoval:
            return OperationEstimates.streamCopy(sizes: items.map(\.fileSize))
        case .ocr:
            return OperationEstimates.ocr(
                durations: items.compactMap(\.durationSeconds),
                sampleIntervalSeconds: interval, level: ocr.recognitionLevel)
        case .writeTags:
            return OperationEstimate(
                filesWritten: items.count, bytesAdded: 0,
                seconds: Double(items.count) * 0.5, timeLabel: "of writing")
        }
    }

    func command(preset: EncodeJob.Preset, mode: RemuxJob.Mode) -> String {
        switch self {
        case .optimize:
            "ffmpeg -i {in} -c copy -movflags +faststart {out}"
        case .repair:
            "ffmpeg -i {in} -c copy {out}"
        case .encode:
            preset == .h264
                ? "ffmpeg -i {in} -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac {out}"
                : "ffmpeg -i {in} -c:v libx265 -preset medium -crf 22 -tag:v hvc1 -c:a aac {out}"
        case .join:
            "ffmpeg -f concat -safe 0 -i parts.txt -c copy {out}"
        case .clipExport:
            "ffmpeg -ss {start} -to {end} -i {in} -c copy {out}"
        case .blockRemoval:
            "ffmpeg -i {in} -filter_complex \"select between kept ranges\" {out}"
        case .ocr:
            "Vision · VNRecognizeTextRequest on sampled frames — no command, no file"
        case .writeTags:
            "metaflac / AtomicParsley, per container"
        }
    }

    // MARK: - Running

    /// One operation, N items, one queue. The runner still executes them
    /// one at a time.
    func enqueue(
        _ items: [MediaItem], order: [UUID], on runner: JobRunner,
        preset: EncodeJob.Preset, mode: RemuxJob.Mode,
        ocr: OcrSettings, interval: Double
    ) async throws {
        switch self {
        case .optimize, .repair:
            await runner.register(RemuxJob.self)
            for item in items {
                _ = try await RemuxJob.enqueue(
                    on: runner, itemID: item.id, mode: self == .optimize ? .optimize : .repair)
            }
        case .encode:
            await runner.register(EncodeJob.self)
            for item in items {
                _ = try await EncodeJob.enqueue(on: runner, itemID: item.id, preset: preset)
            }
        case .clipExport:
            await runner.register(ClipExportJob.self)
            for item in items {
                _ = try await ClipExportJob.enqueue(on: runner, clipID: item.id)
            }
        case .blockRemoval:
            await runner.register(BlockRemovalJob.self)
            for item in items {
                _ = try await BlockRemovalJob.enqueue(on: runner, itemID: item.id)
            }
        case .ocr:
            await runner.register(OcrJob.self)
            for item in items {
                _ = try await OcrJob.enqueue(
                    on: runner, itemID: item.id, settings: ocr, sampleIntervalSeconds: interval)
            }
        case .join:
            guard let first = items.first else { return }
            await runner.register(JoinJob.self)
            _ = try await JoinJob.enqueue(
                on: runner, sourceID: first.sourceID, folderPath: first.folderPath,
                itemIDs: order)
        case .writeTags:
            await runner.register(WritebackJob.self)
            _ = try await WritebackJob.enqueue(
                on: runner, itemIDs: items.map(\.id),
                scopeDescription: "selection (\(items.count) files)")
        }
    }
}
