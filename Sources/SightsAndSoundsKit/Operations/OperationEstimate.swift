import Foundation

/// What an operation is about to cost: files written, bytes added, time
/// taken.
///
/// `≈ 22.6 GB added to disk` is the number that changes someone's mind,
/// and it has to be there before the job is queued rather than after.
/// Every figure is an estimate and says so — the point is the order of
/// magnitude, not a promise.
public struct OperationEstimate: Sendable, Equatable {
    public var filesWritten: Int
    public var bytesAdded: Int64
    public var seconds: Double
    /// What the time figure is time *of* — "of encoding", "of copying",
    /// "of scanning". The label changes because the activity does.
    public var timeLabel: String

    public init(
        filesWritten: Int = 0, bytesAdded: Int64 = 0,
        seconds: Double = 0, timeLabel: String = "of work"
    ) {
        self.filesWritten = filesWritten
        self.bytesAdded = bytesAdded
        self.seconds = seconds
        self.timeLabel = timeLabel
    }

    public var isEmpty: Bool { filesWritten == 0 && bytesAdded == 0 }
}

/// The estimate functions, one per operation kind.
///
/// They are deliberately crude and deliberately in one place: a rate per
/// operation, applied to the selection. A wrong estimate that is visibly
/// an estimate is far better than no number at all, and far better than a
/// number computed differently in three views.
public enum OperationEstimates {
    /// Copying streams runs at roughly disk speed. 200 MB/s is a
    /// conservative figure for an SSD and honest for a spinning disk
    /// under other load.
    static let copyBytesPerSecond: Double = 200_000_000
    /// Encoding is bounded by the CPU, not the disk. About 1.5× realtime
    /// for H.264 on Apple silicon, which is the order of magnitude that
    /// matters.
    static let encodeRealtimeFactor: Double = 1.5

    /// A stream copy: the output is the same size as the input.
    public static func streamCopy(sizes: [Int64], label: String = "of copying") -> OperationEstimate {
        let total = sizes.reduce(Int64(0), +)
        return OperationEstimate(
            filesWritten: sizes.count,
            bytesAdded: total,
            seconds: Double(total) / copyBytesPerSecond,
            timeLabel: label)
    }

    /// Re-encoding: bitrate × duration, using the preset's target rate.
    /// The only operation that loses a generation, and the only one whose
    /// output is not the input's size.
    public static func encode(
        durations: [Double], targetBitsPerSecond: Int
    ) -> OperationEstimate {
        let seconds = durations.reduce(0, +)
        let bytes = Int64(seconds * Double(targetBitsPerSecond) / 8)
        return OperationEstimate(
            filesWritten: durations.count,
            bytesAdded: bytes,
            seconds: seconds / encodeRealtimeFactor,
            timeLabel: "of encoding")
    }

    /// A join writes one file the size of its parts.
    public static func join(sizes: [Int64]) -> OperationEstimate {
        guard sizes.count > 1 else { return OperationEstimate() }
        let total = sizes.reduce(Int64(0), +)
        return OperationEstimate(
            filesWritten: 1, bytesAdded: total,
            seconds: Double(total) / copyBytesPerSecond, timeLabel: "of copying")
    }

    /// A clip export writes the clip's share of the parent's bytes.
    public static func clipExport(
        clipSeconds: Double, parentSeconds: Double, parentBytes: Int64
    ) -> OperationEstimate {
        guard parentSeconds > 0 else { return OperationEstimate(filesWritten: 1) }
        let share = max(0, min(1, clipSeconds / parentSeconds))
        let bytes = Int64(Double(parentBytes) * share)
        return OperationEstimate(
            filesWritten: 1, bytesAdded: bytes,
            seconds: Double(bytes) / copyBytesPerSecond, timeLabel: "of copying")
    }

    /// Block removal writes what it KEEPS — the same ranges that drew the
    /// timeline, so the picture and the number cannot drift.
    public static func blockRemoval(
        totalSeconds: Double, hiddenSeconds: Double, sourceBytes: Int64
    ) -> OperationEstimate {
        guard totalSeconds > 0 else { return OperationEstimate(filesWritten: 1) }
        let keptShare = max(0, min(1, (totalSeconds - hiddenSeconds) / totalSeconds))
        let bytes = Int64(Double(sourceBytes) * keptShare)
        return OperationEstimate(
            filesWritten: 1, bytesAdded: bytes,
            seconds: Double(bytes) / copyBytesPerSecond, timeLabel: "of copying")
    }

    /// OCR writes no file at all — the only one here that doesn't. Its
    /// cost is frames and time. Roughly 25 frames a second accurate, 250
    /// fast, both including the seek.
    public static func ocr(
        durations: [Double], sampleIntervalSeconds: Double, level: OcrSettings.RecognitionLevel
    ) -> OperationEstimate {
        let frames = OcrJob.frameCount(
            durations: durations, sampleIntervalSeconds: sampleIntervalSeconds)
        let framesPerSecond: Double = level == .fast ? 250 : 25
        return OperationEstimate(
            filesWritten: 0, bytesAdded: 0,
            seconds: Double(frames) / framesPerSecond, timeLabel: "of scanning")
    }

    /// Frames, for the label that says so.
    public static func ocrFrames(durations: [Double], sampleIntervalSeconds: Double) -> Int {
        OcrJob.frameCount(durations: durations, sampleIntervalSeconds: sampleIntervalSeconds)
    }
}
