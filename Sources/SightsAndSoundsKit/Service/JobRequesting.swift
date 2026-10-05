import Foundation

/// The work a window asks its library to do in the background. The jobs
/// run where the library's files are, on its one runner; a window names
/// the work and says whether it will wait.
public protocol JobRequesting: Sendable {
    /// Queue the job for a request and start the queue. Returns the job
    /// queued, or nil when the request is a library sweep and one was
    /// already pending.
    @discardableResult
    func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord?

    /// Move a job already queued to the front, and wait until it has
    /// settled — for the one job somebody is sitting in front of. A job
    /// that is not queued (running, done, gone) is only waited for.
    func runNextAndWait(jobID: UUID) async throws

    /// One job's row as it stands — its state, how far it has got, what
    /// came of it. Nil when there is no such job.
    func job(id: UUID) async throws -> JobRecord?

    /// Stop a job: one still queued is taken out of the queue, one
    /// running stops at its next safe point. A job already settled is
    /// left as it is.
    func cancelJob(id: UUID) async throws

    /// Wake the library's workers: hashes, thumbnails and the duplicate
    /// sweeps, for whatever has arrived since they last ran. A signal,
    /// not a command — asked for while they are pending, it queues
    /// nothing — and it returns once they are queued and the queue
    /// started, not when they are done. Said after an import, or any
    /// work that leaves new files behind.
    func wakeWorkers() async throws
}

public enum JobRequest: Codable, Equatable, Sendable {
    /// Read the text on screen in one item's video.
    case recogniseText(itemID: UUID)
    /// Join a folder's files into one.
    case joinFolder(sourceID: UUID, folderPath: String)
    /// Write the library's tags into the files.
    case writeTags(itemIDs: [UUID], scope: String)
    /// Put back the tags a snapshot recorded.
    case restoreSnapshot(UUID)
    case remux(itemID: UUID, mode: RemuxJob.Mode)
    case encode(itemID: UUID, preset: EncodeJob.Preset)
    /// Save a segment as a file of its own.
    case exportClip(clipID: UUID)
    /// Write a copy of the file without its hidden blocks.
    case removeBlocks(itemID: UUID)
    /// Sweep embedded metadata: of these items, or (nil) of the library.
    case metadataSweep(itemIDs: [UUID]?)
    /// Examine these items' files for Media Signal.
    case examine(itemIDs: [UUID])
    /// Take items out of the library and leave their files where they
    /// are, writing their tags into the files first if asked.
    case removeFromLibrary(itemIDs: [UUID], writeTagsFirst: Bool)
    /// Move these items' files into the folders a template gives them.
    case reorganize(template: String, itemIDs: [UUID])
    /// Read the text on screen in one item's video, with these settings
    /// and this far between the frames read.
    case recogniseTextSampled(itemID: UUID, settings: OcrSettings, sampleIntervalSeconds: Double)
    /// Join these of a folder's files into one, in this order.
    case joinItems(sourceID: UUID, folderPath: String, itemIDs: [UUID])
    /// Compare the library with the disk.
    case validation
    /// Bring these files of a source into the library, giving each what
    /// was staged for them.
    case importFiles(sourceID: UUID, relativePaths: [String], staging: ImportStaging?)

    /// A sweep of the whole library. It is a signal rather than a
    /// command: one at most is ever pending, and asking again while one
    /// is queues nothing.
    public var isLibrarySweep: Bool {
        switch self {
        case .validation, .metadataSweep(itemIDs: nil): true
        default: false
        }
    }
}

public enum JobWait: String, Codable, Sendable {
    /// Return as soon as the job is queued and the queue started.
    case none
    /// Return as soon as the job is queued, and leave the queue as it
    /// is. For a caller that may yet take the job back — a run that was
    /// cancelled while this was on its way — and starts the queue itself
    /// once it knows it still wants it (`jobQueue(kind:startingQueue:)`).
    case queued
    /// Return when the work is done. Somebody is waiting, so a job
    /// queued for this request goes next after the one running, rather
    /// than behind every sweep queued before it. For a library sweep it
    /// means "when no sweep of that kind is pending", whoever queued it.
    case settled
}
