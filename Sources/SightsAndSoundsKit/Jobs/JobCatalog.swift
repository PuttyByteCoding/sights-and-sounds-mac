import Foundation

/// Every job type the Kit can queue — what a library's runner is built
/// with. A queued row outlives the session that queued it, so the runner
/// must know its kind from the first drain, not once some window has
/// registered it; a kind missing here fails its queued rows with "no
/// registered job type". A test checks this list against every `kind`
/// the Kit declares.
public enum JobCatalog {
    public static let all: [any Job.Type] = [
        ImportJob.self, ContentHashJob.self, ThumbnailBatchJob.self,
        HashDuplicateSweepJob.self, FingerprintCaptureJob.self,
        FingerprintMatchSweepJob.self, ClipExportJob.self, RemuxJob.self,
        EncodeJob.self, BlockRemovalJob.self, OcrJob.self, JoinJob.self,
        ReorganizeJob.self, WritebackJob.self, RestoreTagsJob.self,
        ValidationJob.self, MetadataSweepJob.self, MediaSignalJob.self,
        RepairJob.self,
    ]
}
