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

    var fileAccess: any FileAccess
    var stages: [any SignalStage]
    let scope: Set<UUID>?
    /// Kept as it arrived, so a sweep that steps aside can queue its own
    /// return with the same scope.
    let payload: Data?

    /// Files examined at the same time. On local disk a file costs a few
    /// seconds of mostly single-threaded work; on a network share or a
    /// spinning disk it costs mostly waiting. Both leave room for a second
    /// and a third, and three 1080p files in hand is under a gigabyte.
    var filesAtOnce = 3

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
        self.payload = payload
        scope = payload.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            .map { Set($0.itemIDs) }
    }

    init(stages: [any SignalStage], scope: Set<UUID>? = nil, fileAccess: any FileAccess = LiveFileAccess()) {
        self.fileAccess = fileAccess
        self.stages = stages
        self.scope = scope
        payload = scope.flatMap { try? JSONEncoder().encode(Payload(itemIDs: Array($0))) }
    }

    @discardableResult
    public static func enqueue(on runner: JobRunner, itemIDs: [UUID]) async throws -> JobRecord {
        try await runner.enqueue(
            MediaSignalJob.self, payload: try JSONEncoder().encode(Payload(itemIDs: itemIDs)))
    }

    public func run(_ context: JobContext) async throws {
        let library = context.library
        // Days of work with nobody at the keyboard: without this the Mac
        // idles to sleep and the sweep with it, and App Nap throttles what
        // is left. The display may still sleep.
        let awake = Awake(reason: "Examining media files")
        defer { awake.end() }

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

        // A visit is one item in one pass: the file is opened once for
        // every stage of that pass it still lacks. Passes run in order
        // across the whole library, and never overlap.
        let passes = Set(stages.map(\.pass)).sorted().map { pass in
            work.compactMap { entry -> Visit? in
                let due = entry.stages.compactMap { byName[$0] }.filter { $0.pass == pass }
                return due.isEmpty ? nil : Visit(item: entry.item, stages: due)
            }
        }
        let total = passes.reduce(0) { $0 + $1.count }

        var examined = 0
        var launched = 0
        var failedItems: Set<UUID> = []
        var spent: [String: Double] = [:]
        await context.reportProgress(current: 0, total: total)

        for visits in passes where !visits.isEmpty {
            let started = Date()
            var waiting = visits.makeIterator()
            var steppedAside = false
            try await withThrowingTaskGroup(of: VisitOutcome.self) { group in
                // Start the next visit, unless the sweep should be stopping.
                // One lane runs a library's jobs, so a sweep that takes days
                // would make an import or an export wait days: before each
                // new visit it looks for anything queued, and if there is,
                // starts nothing more. What is in hand is finished first.
                func startNext() async throws -> Bool {
                    try await context.checkCancellation()
                    if launched > 0, try Self.anotherJobIsWaiting(in: library, forScopedSweep: scope != nil) {
                        steppedAside = true
                        return false
                    }
                    guard let visit = waiting.next() else { return false }
                    guard let source = sources[visit.item.sourceID] else { return true }
                    let job = self
                    launched += 1
                    group.addTask { try await job.perform(visit, from: source, context: context) }
                    return true
                }
                var running = 0
                while running < max(filesAtOnce, 1), try await startNext() { running += 1 }
                while let outcome = try await group.next() {
                    examined += 1
                    if outcome.failed { failedItems.insert(outcome.itemID) }
                    for (stage, seconds) in outcome.seconds { spent[stage, default: 0] += seconds }
                    await context.reportProgress(current: examined, total: total)
                    if !steppedAside { _ = try await startNext() }
                }
            }
            AppLog.shared.info(
                "signal",
                "pass \(visits[0].stages[0].pass): \(visits.count) visits in \(Int(Date().timeIntervalSince(started))) s")
            if steppedAside {
                try await library.writer.write { db in
                    try JobRecord(kind: Self.kind, payload: payload).insert(db)
                }
                await context.setSummary(
                    "\(examined) of \(total) visits done; stepped aside for other work and continues after it. "
                        + Self.account(of: spent))
                return
            }
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

        let outcome = failedItems.isEmpty
            ? "\(examined) visits to \(work.count) items"
            : "\(examined) visits to \(work.count) items, \(failedItems.count) with a stage that failed"
        await context.setSummary(spent.isEmpty ? outcome : outcome + ". " + Self.account(of: spent))
    }

    /// One item in one pass.
    struct Visit: Sendable {
        var item: MediaItem
        var stages: [any SignalStage]
    }

    struct VisitOutcome: Sendable {
        var itemID: UUID
        var failed = false
        var seconds: [String: Double] = [:]
    }

    /// Where the time went, largest first: "Time: sequences 58 %, sound 31 %".
    /// A sweep that is slower than expected says why on its own row.
    static func account(of spent: [String: Double]) -> String {
        let total = spent.values.reduce(0, +)
        guard total > 0 else { return "" }
        let shares = spent.sorted { $0.value > $1.value }.prefix(4).map { stage, seconds in
            "\(stage) \(Int((seconds / total * 100).rounded())) %"
        }
        return "Time: " + shares.joined(separator: ", ")
    }

    /// Take one item through the stages of one pass.
    func perform(_ visit: Visit, from source: Source, context: JobContext) async throws -> VisitOutcome {
        let library = context.library
        var outcome = VisitOutcome(itemID: visit.item.id)
        let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
            .appendingPathComponent(visit.item.relativePath)
        let input = SignalStageInput(url: url, kind: visit.item.kind) { await context.isCancelled }

        for stage in visit.stages {
            let started = Date()
            // Written before the stage starts, so it is what a crash
            // leaves behind. A file that takes the app down is then a
            // reported failure on the next launch instead of the first
            // thing the sweep opens again, every time.
            try library.recordSignalStage(
                itemID: visit.item.id, stage: stage.name, version: stage.version,
                findings: SignalFindings(), failure: Self.interruptedMessage)
            do {
                let findings = try await Self.examine(
                    input, with: stage, givingUpAfter: stageTimeout(visit.item))
                try library.recordSignalStage(
                    itemID: visit.item.id, stage: stage.name, version: stage.version, findings: findings)
            } catch is CancellationError {
                // Stopped by hand: the file did nothing wrong.
                try library.forgetSignalStage(itemID: visit.item.id, stage: stage.name)
                throw CancellationError()
            } catch {
                // A drive that stopped answering fails every file on it
                // the same way. Marking them would bury the real failures
                // under thousands of false ones, so the sweep stops and
                // leaves them unmarked for when it is back.
                if !source.isOnline(using: fileAccess) {
                    try library.forgetSignalStage(itemID: visit.item.id, stage: stage.name)
                    throw SourceWentOffline(sourceName: source.name)
                }
                try library.recordSignalStage(
                    itemID: visit.item.id, stage: stage.name, version: stage.version,
                    findings: SignalFindings(), failure: "\(error)")
                outcome.failed = true
            }
            outcome.seconds[stage.name, default: 0] += Date().timeIntervalSince(started)
            try await context.checkCancellation()
        }
        // After every visit, so what is known so far is already read: the
        // cheap pass alone says "re-encoded by HandBrake".
        try Self.drawConclusions(for: visit.item.id, in: library)
        return outcome
    }

    /// A sweep of the whole library steps aside for anything. A scoped
    /// one, which somebody asked for and is waiting on, steps aside for
    /// anything but another sweep: otherwise it and the whole-library
    /// sweep it interrupted would hand the lane back and forth one file
    /// at a time, leaving a job row behind for each.
    static func anotherJobIsWaiting(in library: LibraryDatabase, forScopedSweep scoped: Bool) throws -> Bool {
        try library.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM job WHERE state = 'queued' AND (? = 0 OR kind <> ?))",
                arguments: [scoped ? 1 : 0, kind]) ?? false
        }
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

    /// Holds the system awake for as long as it lives.
    final class Awake: @unchecked Sendable {
        private let token: NSObjectProtocol
        init(reason: String) {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        }
        func end() { ProcessInfo.processInfo.endActivity(token) }
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
