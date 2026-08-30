import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Recently Watched, and the boundaries of what these columns can say.
@Suite struct WatchHistoryTests {

    private func watch(
        _ library: LibraryDatabase, _ id: UUID, at date: Date, position: Double = 60
    ) throws {
        try library.recordPlaybackStop(
            itemID: id, positionSeconds: position, durationSeconds: 600, at: date)
    }

    @Test func mostRecentFirst() throws {
        let f = try FilterFixture()
        let old = Date(timeIntervalSince1970: 1_000_000)
        try watch(f.library, f.show1995.id, at: old)
        try watch(f.library, f.show2001.id, at: old.addingTimeInterval(86_400))

        let history = try f.library.recentlyWatched()
        #expect(history.first?.id == f.show2001.id)
        #expect(history.count == 2)
    }

    /// Never watched is ABSENT, not present with a null date — "not in the
    /// history" and "watched at an unknown time" are different facts.
    @Test func neverWatchedItemsAreAbsent() throws {
        let f = try FilterFixture()
        try watch(f.library, f.show1995.id, at: Date())

        let history = try f.library.recentlyWatched()
        #expect(history.map(\.id) == [f.show1995.id])
        #expect(try f.library.watchedItemCount() == 1)
    }

    /// The count is the history's true size, so the window can say when
    /// the limit is showing a slice rather than everything.
    @Test func theLimitBoundsTheRowsNotTheCount() throws {
        let f = try FilterFixture()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (offset, id) in [f.show1995.id, f.show2001.id, f.audioOnly.id].enumerated() {
            try watch(f.library, id, at: base.addingTimeInterval(Double(offset) * 60))
        }
        #expect(try f.library.recentlyWatched(limit: 2).count == 2)
        #expect(try f.library.watchedItemCount() == 3)
    }

    /// Watching something twice is ONE row carrying the later date — the
    /// limit of building on these columns rather than an event log, and
    /// the reason this window is "Recently Watched" and not "History".
    @Test func rewatchingUpdatesTheRowRatherThanAddingOne() throws {
        let f = try FilterFixture()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = first.addingTimeInterval(86_400)
        try watch(f.library, f.show1995.id, at: first)
        try watch(f.library, f.show1995.id, at: second)

        let history = try f.library.recentlyWatched()
        #expect(history.count == 1)
        #expect(history.first?.lastWatchedAt == second)
    }

    /// A completed play-through tallies and marks; the resume position is
    /// cleared near either edge by recordPlaybackStop's own rule.
    @Test func completionTalliesTheWatch() throws {
        let f = try FilterFixture()
        try f.library.recordPlaybackCompletion(itemID: f.show1995.id)
        try f.library.recordPlaybackCompletion(itemID: f.show1995.id)

        let row = try f.library.recentlyWatched().first
        #expect(row?.watchCount == 2)
        #expect(row?.completed == true)
    }
}
