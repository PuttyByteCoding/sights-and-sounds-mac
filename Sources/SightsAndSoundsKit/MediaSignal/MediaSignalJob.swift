import Foundation
import GRDB

/// Runs every signal stage an item still lacks: what the file declares,
/// how its frames are timed, and (as later stages arrive) what its picture
/// and sound measure.
///
/// Like every sweep it fills in what is missing and nothing else. Each
/// stage is recorded as it finishes, so stopping the job loses the stage
/// in flight and no more; a stage that fails leaves a marker carrying the
/// reason, so a file that cannot be read is reported once rather than
/// re-read on every run.
public struct MediaSignalJob: Job {
    public static let kind = "mediaSignal.sweep"

    /// A scoped run, for a window looking at particular items now.
    public struct Payload: Codable, Sendable {
        public var itemIDs: [UUID]
        public init(itemIDs: [UUID]) { self.itemIDs = itemIDs }
    }

    let fileAccess: any FileAccess
    let stages: [any SignalStage]
    let scope: Set<UUID>?

    /// Seconds a stage may take on one item before the sweep gives up on
    /// it and moves on.
    var stageTimeout: @Sendable (MediaItem) -> Double = { item in 600 + (item.durationSeconds ?? 0) / 4 }

    /// The drive a file lives on stopped answering part-way through.
    public struct SourceWentOffline: Error, CustomStringConvertible, Equatable {
        public let sourceName: String
        public var description: String {
            "\(sourceName) went offline; stopped without marking the files that could not be read"
        }
    }

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
        stages = SignalStages.all
        scope = payload.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            .map { Set($0.itemIDs) }
    }

    init(stages: [any SignalStage], scope: Set<UUID>? = nil, fileAccess: any FileAccess = LiveFileAccess()) {
        self.fileAccess = fileAccess
        self.stages = stages
        self.scope = scope
    }

    @discardableResult
    public static func enqueue(on runner: JobRunner, itemIDs: [UUID]) async throws -> JobRecord {
        try await runner.enqueue(
            MediaSignalJob.self, payload: try JSONEncoder().encode(Payload(itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library

        // Only sources reachable right now. An offline drive must leave no
        // marker: a marker means "looked, and this is what was there".
        let sources = try await library.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let online = Set(
            sources.values.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))

        let work = try library.itemsNeedingSignalStages(stages)
            .filter { online.contains($0.item.sourceID) }
            .filter { scope?.contains($0.item.id) ?? true }
        let byName = Dictionary(uniqueKeysWithValues: stages.map { ($0.name, $0) })

        var examined = 0
        var failedItems = 0
        await context.reportProgress(current: 0, total: work.count)

        for (index, entry) in work.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[entry.item.sourceID] else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(entry.item.relativePath)
            let input = SignalStageInput(url: url, kind: entry.item.kind) {
                await context.isCancelled
            }

            var failed = false
            for stageName in entry.stages {
                guard let stage = byName[stageName] else { continue }
                // Written before the stage starts, so it is what a crash
                // leaves behind. A file that takes the app down is then a
                // reported failure on the next launch instead of the first
                // thing the sweep opens again, every time.
                try library.recordSignalStage(
                    itemID: entry.item.id, stage: stage.name, version: stage.version,
                    findings: SignalFindings(), failure: Self.interruptedMessage)
                do {
                    let findings = try await Self.examine(
                        input, with: stage, givingUpAfter: stageTimeout(entry.item))
                    try library.recordSignalStage(
                        itemID: entry.item.id, stage: stage.name, version: stage.version,
                        findings: findings)
                } catch is CancellationError {
                    // Stopped by hand: the file did nothing wrong.
                    try library.forgetSignalStage(itemID: entry.item.id, stage: stage.name)
                    throw CancellationError()
                } catch {
                    // A drive that stopped answering fails every file on it
                    // the same way. Marking them would bury the real
                    // failures under thousands of false ones, so the sweep
                    // stops and leaves them unmarked for when it is back.
                    if !source.isOnline(using: fileAccess) {
                        try library.forgetSignalStage(itemID: entry.item.id, stage: stage.name)
                        throw SourceWentOffline(sourceName: source.name)
                    }
                    try library.recordSignalStage(
                        itemID: entry.item.id, stage: stage.name, version: stage.version,
                        findings: SignalFindings(), failure: "\(error)")
                    failed = true
                }
                try await context.checkCancellation()
            }
            try Self.drawConclusions(for: entry.item.id, in: library)
            examined += 1
            if failed { failedItems += 1 }
            await context.reportProgress(current: index + 1, total: work.count)
        }

        // Items whose findings are complete but whose conclusions were
        // drawn by older rules, or never: rows are read, not files, so
        // this covers offline sources too.
        var redrawn = 0
        if scope == nil {
            for itemID in try library.itemsNeedingSignalConclusions(rulesVersion: SignalRules.version) {
                try await context.checkCancellation()
                try Self.drawConclusions(for: itemID, in: library)
                redrawn += 1
            }
        }
        if examined == 0, redrawn > 0 {
            await context.setSummary("conclusions re-drawn for \(redrawn) items")
            return
        }

        await context.setSummary(
            failedItems == 0
                ? "\(examined) items examined"
                : "\(examined) items examined, \(failedItems) with a stage that failed")
    }

    static let interruptedMessage =
        "interrupted: the app quit, or crashed, while this stage was examining the file. Retry failed examines it again."

    struct StageGaveUp: Error, CustomStringConvertible {
        let seconds: Double
        var description: String {
            "gave up after \(Int(seconds)) s: the stage never finished, which is usually a damaged file the decoder cannot get past"
        }
    }

    /// Run one stage, but not for ever. A decoder blocked inside a damaged
    /// file never returns and cannot be interrupted, and a structured task
    /// would wait for it; so the stage runs on a task of its own and
    /// whichever of "it finished" and "time is up" comes first is the
    /// answer. A stage that is given up on is left behind, still blocked.
    /// That costs a thread; the alternative costs the rest of the sweep.
    static func examine(
        _ input: SignalStageInput, with stage: any SignalStage, givingUpAfter seconds: Double
    ) async throws -> SignalFindings {
        let once = OnceOnly()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task.detached(priority: .utility) {
                do {
                    let findings = try await stage.examine(input)
                    if once.claim() { continuation.resume(returning: findings) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.05) * 1_000_000_000))
                guard once.claim() else { return }
                work.cancel()
                continuation.resume(throwing: StageGaveUp(seconds: seconds))
            }
        }
    }

    /// Whoever asks first gets `true`, and only they resume the continuation.
    final class OnceOnly: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }
    }

    static func drawConclusions(for itemID: UUID, in library: LibraryDatabase) throws {
        let (evidence, conclusions) = SignalInferenceRules.conclude(try library.signalFacts(itemID: itemID))
        try library.replaceSignalConclusions(
            itemID: itemID, evidence: evidence, conclusions: conclusions, rulesVersion: SignalRules.version)
    }
}
