import Foundation

// MARK: - JobRequesting

extension LocalLibraryService {
    @discardableResult
    public func run(_ request: JobRequest, wait: JobWait) async throws -> JobRecord? {
        if request.isLibrarySweep {
            let sweep: any Job.Type = request == .validation ? ValidationJob.self : MetadataSweepJob.self
            let job = try await runner.enqueueUnlessPending(sweep)
            switch wait {
            case .none:
                await runner.startDraining()
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

        let job = try await enqueue(request)
        switch wait {
        case .none:
            await runner.startDraining()
        case .settled:
            try await runner.runNext(job.id)
            try await runner.waitUntilSettled([job.id])
        }
        return job
    }

    /// Through each job's own `enqueue`, so the payload is the one the
    /// job reads.
    private func enqueue(_ request: JobRequest) async throws -> JobRecord {
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
        case .validation:
            try await runner.enqueue(ValidationJob.self)
        }
    }
}
