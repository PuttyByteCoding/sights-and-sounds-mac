import Foundation
import GRDB

/// A kind of thing a window might be showing. The hub reports changes in
/// these terms rather than in tables, so a subscriber asks "did anything
/// I draw change?" without knowing the schema.
public enum LibraryChangeDomain: String, Sendable, Hashable, CaseIterable {
    /// Items appearing, leaving, or changing in a way a listing shows.
    case items
    /// Which tags and field values items carry.
    case tagging
    /// Categories, tags, aliases, fields, key bindings.
    case vocabulary
    case sources
    case savedFilters
    case duplicates
    /// Per-item extras: blocks, tag snapshots, recognised text.
    case itemDetails

    var tables: [String] {
        switch self {
        case .items: ["mediaItem"]
        case .tagging: ["mediaItemTag", "mediaItemFieldValue"]
        case .vocabulary: ["tagCategory", "tag", "tagAlias", "fieldDefinition", "tagKeyBinding"]
        case .sources: ["source"]
        case .savedFilters: ["savedFilter"]
        case .duplicates: ["duplicateCandidate"]
        case .itemDetails: ["videoBlock", "embeddedTagSnapshot", "ocrTextLine"]
        }
    }
}

/// Says what changed in a library, to anyone who asked, whoever wrote it.
///
/// Nothing in the app used to say "this data changed": a window heard
/// about a change only if it made it, or if another browse window
/// happened to refresh. The player's edits, a view's direct writes and a
/// background import were all invisible to everyone else. The database
/// knows, per committed transaction, what was written; this turns that
/// into domains and delivers them. No write site has to do anything,
/// including the ones that do not exist yet.
///
/// See docs/superpowers/specs/2026-09-20-library-change-hub-design.md.
/// One coalesced delivery.
public struct LibraryChange: Sendable {
    public let domains: Set<LibraryChangeDomain>
    /// When the newest commit in this delivery landed. A refresh that
    /// BEGAN after this has already read everything the delivery is
    /// about, which is how a window avoids refreshing twice for its own
    /// write.
    public let lastCommitAt: ContinuousClock.Instant
}

public final class LibraryChangeHub: Sendable {
    public typealias Handler = @Sendable (LibraryChange) -> Void

    /// `mediaItem` columns that are written constantly and that no
    /// listing shows: the hash sweep's, and the player's progress. Every
    /// OTHER column is observed, so a column a later migration adds counts
    /// by default.
    static let unlistedItemColumns: Set<String> = [
        "contentHash", "resumePositionSeconds", "lastWatchedAt", "watchCount",
    ]

    /// A burst of commits is delivered once, this long after its first.
    static let coalescingWindow: DispatchTimeInterval = .milliseconds(100)

    private struct State {
        var handlers: [UUID: Handler] = [:]
        var pending: Set<LibraryChangeDomain> = []
        var lastCommitAt = ContinuousClock.now
        var flushScheduled = false
        var observations: [AnyDatabaseCancellable] = []
    }

    private let state = LockedState(State())
    private let delivery = DispatchQueue(label: "sas.library-change-hub")

    init(writer: any DatabaseWriter) {
        var observations: [AnyDatabaseCancellable] = []
        for domain in LibraryChangeDomain.allCases {
            guard let regions = try? writer.read({ try Self.regions(for: domain, $0) }),
                  !regions.isEmpty
            else { continue }
            let observation = DatabaseRegionObservation(tracking: regions)
            observations.append(observation.start(in: writer, onError: { error in
                AppLog.shared.error("changes", "stopped observing \(domain.rawValue): \(error)")
            }, onChange: { [weak self] _ in
                self?.note(domain)
            }))
        }
        state.withLock { $0.observations = observations }
    }

    /// What to track for a domain. Tables that do not exist (a library
    /// stopped at an older schema, in a migration test) are skipped.
    private static func regions(
        for domain: LibraryChangeDomain, _ db: Database
    ) throws -> [any DatabaseRegionConvertible] {
        var regions: [any DatabaseRegionConvertible] = []
        for table in domain.tables where try db.tableExists(table) {
            guard table == "mediaItem" else {
                regions.append(Table(table))
                continue
            }
            let listed = try db.columns(in: table).map(\.name)
                .filter { !unlistedItemColumns.contains($0) }
            let columnList = listed.map { "\"\($0)\"" }.joined(separator: ", ")
            regions.append(SQLRequest<Row>(sql: "SELECT \(columnList) FROM mediaItem"))
        }
        return regions
    }

    /// Hear about changes until the returned subscription is cancelled or
    /// released. Deliveries are coalesced and arrive on a background
    /// queue; hop to your own actor.
    public func subscribe(_ handler: @escaping Handler) -> Subscription {
        let id = UUID()
        state.withLock { $0.handlers[id] = handler }
        return Subscription { [weak self] in
            self?.state.withLock { $0.handlers[id] = nil }
        }
    }

    private func note(_ domain: LibraryChangeDomain) {
        let schedule = state.withLock { state -> Bool in
            state.pending.insert(domain)
            state.lastCommitAt = .now
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard schedule else { return }
        delivery.asyncAfter(deadline: .now() + Self.coalescingWindow) { [weak self] in self?.flush() }
    }

    private func flush() {
        let (change, handlers) = state.withLock { state -> (LibraryChange, [Handler]) in
            defer {
                state.pending = []
                state.flushScheduled = false
            }
            return (
                LibraryChange(domains: state.pending, lastCommitAt: state.lastCommitAt),
                Array(state.handlers.values))
        }
        guard !change.domains.isEmpty else { return }
        for handler in handlers { handler(change) }
    }

    /// Ends when cancelled, and when released.
    public final class Subscription: Sendable {
        private let onCancel: @Sendable () -> Void
        init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        public func cancel() { onCancel() }
        deinit { onCancel() }
    }
}

/// A value behind a lock. (`OSAllocatedUnfairLock` would do, but its
/// closure-only API does not let a lock be held across the `defer` above
/// any more clearly than this.)
final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
