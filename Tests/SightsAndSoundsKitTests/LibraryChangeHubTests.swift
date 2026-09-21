import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The hub turns committed writes into "this kind of thing changed", for
/// any writer: a model, a view, a job, the player. See
/// docs/superpowers/specs/2026-09-20-library-change-hub-design.md.
@Suite struct LibraryChangeHubTests {

    /// Collects what a subscription delivers.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries: [Set<LibraryChangeDomain>] = []
        func receive(_ domains: Set<LibraryChangeDomain>) { lock.withLock { deliveries.append(domains) } }
        var all: [Set<LibraryChangeDomain>] { lock.withLock { deliveries } }
        var union: Set<LibraryChangeDomain> { all.reduce(into: []) { $0.formUnion($1) } }
    }

    /// Long enough for a coalesced delivery to have arrived.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    /// A seeded library whose seeding has already been delivered: the
    /// fixture's own inserts are changes too, and arrive a moment later.
    private func quietFixture() async throws -> FilterFixture {
        let fixture = try FilterFixture()
        try await settle()
        return fixture
    }

    @Test func aTagAssignmentIsTaggingAndNothingElse() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }

        try f.library.assignTag(f.bandB.id, to: f.show1995.id)
        try await settle()

        #expect(inbox.union == [.tagging])
    }

    @Test func vocabularySourcesAndItemsEachSayWhatTheyAre() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }

        try f.library.addAlias("Soundboard", toTag: f.sbd.id)
        try await settle()
        #expect(inbox.union == [.vocabulary])

        try await f.library.writer.write { db in
            try MediaItem(
                sourceID: f.mainSource.id, kind: .video, relativePath: "new/arrival.mp4").insert(db)
        }
        try await settle()
        #expect(inbox.union == [.vocabulary, .items])

        try await f.library.writer.write { db in
            try Source(name: "Another", rootPath: TestRoots.unreachable("Another")).insert(db)
        }
        try await settle()
        #expect(inbox.union == [.vocabulary, .items, .sources])
    }

    /// The hash sweep writes `contentHash` per file and the player writes
    /// the resume position on every pause. No listing shows either, and a
    /// hub that reported them would turn a background sweep into a
    /// refresh storm.
    @Test func whatNoListingShowsIsNotAChange() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }

        try await f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET contentHash = 'abc' WHERE id = ?", arguments: [f.show1995.id])
        }
        try f.library.recordPlaybackStop(itemID: f.show1995.id, positionSeconds: 42, durationSeconds: 100)
        try await f.library.writer.write { db in
            try JobRecord(kind: "test.noise", payload: nil).insert(db)
        }
        try await settle()

        #expect(inbox.all.isEmpty)

        // …while a column a listing does show still counts.
        try await f.library.writer.write { db in
            try db.execute(
                sql: "UPDATE mediaItem SET needsReview = 1 WHERE id = ?", arguments: [f.show1995.id])
        }
        try await settle()
        #expect(inbox.union == [.items])
    }

    @Test func aBurstOfCommitsArrivesAsAHandfulOfDeliveries() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }

        let started = ContinuousClock.now
        for n in 0..<50 {
            try await f.library.writer.write { db in
                try MediaItem(
                    sourceID: f.mainSource.id, kind: .video, relativePath: "burst/\(n).mp4").insert(db)
            }
        }
        let burst = started.duration(to: .now)
        try await settle()

        #expect(inbox.union == [.items])
        // The promise is one delivery at once and then one per 100 ms
        // window, however many commits land. How many windows fifty
        // commits span depends on the machine, so the bound is worked out
        // from how long they took here rather than guessed.
        let windows = Int(burst / .milliseconds(100)) + 1
        #expect(inbox.all.count <= windows + 2)
    }

    /// The first change after a quiet spell goes out at once, and the
    /// window it opens closes silently if nothing else happened.
    @Test func oneEditIsOneDelivery() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }

        try f.library.assignTag(f.bandB.id, to: f.show1995.id)
        try await settle()

        #expect(inbox.all == [[.tagging]])

        // And the hub is ready to be immediate again afterwards.
        try f.library.addAlias("Soundboard", toTag: f.sbd.id)
        try await settle()
        #expect(inbox.all == [[.tagging], [.vocabulary]])
    }

    @Test func aCancelledSubscriptionHearsNothingMore() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }

        subscription.cancel()
        try f.library.assignTag(f.bandB.id, to: f.show1995.id)
        try await settle()

        #expect(inbox.all.isEmpty)
    }

    @Test func aRolledBackWriteIsNotAChange() async throws {
        let f = try await quietFixture()
        let inbox = Inbox()
        let subscription = f.library.changes.subscribe { inbox.receive($0.domains) }
        defer { subscription.cancel() }
        struct Abort: Error {}

        try? await f.library.writer.write { db in
            try MediaItem(
                sourceID: f.mainSource.id, kind: .video, relativePath: "never/was.mp4").insert(db)
            throw Abort()
        }
        try await settle()

        #expect(inbox.all.isEmpty)
    }
}
