import Foundation

// MARK: - JobRequesting

extension LocalLibraryService {
    @discardableResult
    public func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord? {
        guard let runner else { throw ServiceError.noJobRunner }
        if request.isLibrarySweep {
            let sweep: any Job.Type = request == .validation ? ValidationJob.self : MetadataSweepJob.self
            let job = try await runner.enqueueUnlessPending(sweep)
            switch wait {
            case .none:
                await runner.startDraining()
            case .queued:
                break
            case .settled:
                // Waits for its own sweep, never for jobs queued after
                // it; folded into one already pending, for that one.
                if let job {
                    try await runner.waitUntilSettled([job.id])
                } else {
                    try await runner.waitUntilNonePending(of: sweep.kind)
                }
            }
            return job
        }

        let job = try await enqueue(request, on: runner)
        switch wait {
        case .none:
            await runner.startDraining()
        case .queued:
            break
        case .settled:
            try await runner.runNext(job.id)
            try await runner.waitUntilSettled([job.id])
        }
        return job
    }

    /// Through each job's own `enqueue`, so the payload is the one the
    /// job reads.
    public func runNextAndWait(jobID: UUID) async throws {
        guard let runner else { throw ServiceError.noJobRunner }
        try await runner.runNext(jobID)
        try await runner.waitUntilSettled([jobID])
    }

    public func job(id: UUID) async throws -> JobRecord? {
        try await library.read { try JobRecord.fetchOne($0, key: id) }
    }

    public func cancelJob(id: UUID) async throws {
        guard let runner else { throw ServiceError.noJobRunner }
        await runner.requestCancel(id)
    }

    /// Work is decided from the disk and the database inside each job,
    /// so the list here is only which workers there are.
    public func wakeWorkers() async throws {
        guard let runner else { throw ServiceError.noJobRunner }
        _ = try await runner.enqueueUnlessPending(ContentHashJob.self)
        if let libraryID = try library.info()?.libraryID {
            _ = try await ThumbnailBatchJob.enqueueUnlessPending(on: runner, libraryID: libraryID)
        }
        // Duplicates ride the same signal: hash pairs after hashing,
        // fingerprints after capture, matches after both.
        _ = try await runner.enqueueUnlessPending(HashDuplicateSweepJob.self)
        _ = try await runner.enqueueUnlessPending(FingerprintCaptureJob.self)
        _ = try await runner.enqueueUnlessPending(FingerprintMatchSweepJob.self)
        await runner.startDraining()
    }

    private func enqueue(_ request: JobRequest, on runner: JobRunner) async throws -> JobRecord {
        switch request {
        case .recogniseText(let itemID):
            try await OcrJob.enqueue(on: runner, itemID: itemID)
        case .joinFolder(let sourceID, let folderPath):
            try await JoinJob.enqueue(on: runner, sourceID: sourceID, folderPath: folderPath)
        case .writeTags(let itemIDs, let scope):
            try await WritebackJob.enqueue(on: runner, itemIDs: itemIDs, scopeDescription: scope)
        case .restoreSnapshot(let snapshotID):
            try await RestoreTagsJob.enqueue(on: runner, snapshotID: snapshotID)
        case .remux(let itemID, let mode):
            try await RemuxJob.enqueue(on: runner, itemID: itemID, mode: mode)
        case .encode(let itemID, let preset):
            try await EncodeJob.enqueue(on: runner, itemID: itemID, preset: preset)
        case .exportClip(let clipID):
            try await ClipExportJob.enqueue(on: runner, clipID: clipID)
        case .removeBlocks(let itemID):
            try await BlockRemovalJob.enqueue(on: runner, itemID: itemID)
        case .metadataSweep(let itemIDs?):
            try await MetadataSweepJob.enqueue(on: runner, itemIDs: itemIDs)
        case .metadataSweep(itemIDs: nil):
            try await runner.enqueue(MetadataSweepJob.self)
        case .examine(let itemIDs):
            try await MediaSignalJob.enqueue(on: runner, itemIDs: itemIDs)
        case .removeFromLibrary(let itemIDs, let writeTagsFirst):
            try await RemoveFromLibraryJob.enqueue(on: runner, itemIDs: itemIDs, writeTagsFirst: writeTagsFirst)
        case .reorganize(let template, let itemIDs):
            try await ReorganizeJob.enqueue(on: runner, template: template, itemIDs: itemIDs)
        case .recogniseTextSampled(let itemID, let settings, let interval):
            try await OcrJob.enqueue(
                on: runner, itemID: itemID, settings: settings, sampleIntervalSeconds: interval)
        case .joinItems(let sourceID, let folderPath, let itemIDs):
            try await JoinJob.enqueue(on: runner, sourceID: sourceID, folderPath: folderPath, itemIDs: itemIDs)
        case .validation:
            try await runner.enqueue(ValidationJob.self)
        case .importFiles(let sourceID, let relativePaths, let staging):
            try await ImportJob.enqueue(
                on: runner, sourceID: sourceID, relativePaths: relativePaths, staging: staging)
        }
    }
}
