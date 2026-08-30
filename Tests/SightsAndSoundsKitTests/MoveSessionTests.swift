import Foundation
import Testing
@testable import SightsAndSoundsKit

/// A run is the unit anyone puts back, and the plan says what the drive
/// will look like before it runs.
@Suite struct MoveSessionTests {

    /// Grouping by template and timestamp works right up until two runs
    /// share a template a minute apart — so the run carries an id.
    @Test func movesGroupIntoTheRunTheyBelongedTo() throws {
        let f = try FilterFixture()
        let session = UUID()
        try f.library.writer.write { db in
            for (index, name) in ["a", "b", "c"].enumerated() {
                try FileMoveLog(
                    mediaItemID: UUID(), sourceID: f.mainSource.id,
                    fileName: "\(name).mp4", fromPath: "old/\(name).mp4",
                    toPath: "new/\(name).mp4",
                    movedAt: Date().addingTimeInterval(Double(index)),
                    sessionID: session).insert(db)
            }
            // A staging move carries no session and is its own.
            try FileMoveLog(
                mediaItemID: UUID(), sourceID: f.mainSource.id,
                fileName: "staged.mp4", fromPath: "x.mp4", toPath: "_ToDelete/x.mp4",
                movedAt: Date().addingTimeInterval(10)).insert(db)
        }

        let sessions = try f.library.moveSessions()
        #expect(sessions.count == 2)
        #expect(sessions.first { $0.id == session }?.logs.count == 3)
        #expect(sessions.contains { $0.logs.count == 1 && $0.logs[0].fileName == "staged.mp4" })
    }

    /// A half-undone run must never be mistaken for a clean one.
    @Test func sessionStateDistinguishesHalfUndoneRuns() throws {
        let f = try FilterFixture()
        let session = UUID()
        try f.library.writer.write { db in
            try FileMoveLog(
                mediaItemID: UUID(), sourceID: f.mainSource.id, fileName: "a.mp4",
                fromPath: "old/a.mp4", toPath: "new/a.mp4", sessionID: session).insert(db)
            try FileMoveLog(
                mediaItemID: UUID(), sourceID: f.mainSource.id, fileName: "b.mp4",
                fromPath: "old/b.mp4", toPath: "new/b.mp4",
                revertedAt: Date(), sessionID: session).insert(db)
        }
        #expect(try f.library.moveSessions()[0].state == .partlyReverted)
        #expect(try f.library.moveSessions()[0].revertibleCount == 1)
    }

    /// Reverting a whole run skips rows that are already back rather
    /// than throwing on the first one.
    @Test func revertingASessionSkipsWhatIsAlreadyBack() throws {
        let f = try FilterFixture()
        let session = UUID()
        try f.library.writer.write { db in
            try FileMoveLog(
                mediaItemID: f.show1995.id, sourceID: f.mainSource.id, fileName: "a.mp4",
                fromPath: "shows/1995/a.mp4", toPath: "moved/a.mp4",
                revertedAt: Date(), sessionID: session).insert(db)
        }
        let outcome = try f.library.revertSession(session)
        // Nothing left to revert, and no throw.
        #expect(outcome.reverted == 0)
        #expect(outcome.failures.isEmpty)
    }

    // MARK: - Plan shape

    /// The row list answers "what happens to this file"; the folder list
    /// answers "what will my drive look like".
    @Test func aPlanKnowsTheShapeItWouldCreate() {
        let plan = [
            ReorganizePlanEntry(
                itemID: UUID(), fileName: "a.mp4", fromFolder: "in",
                toFolder: "Bands/Ash", reason: nil),
            ReorganizePlanEntry(
                itemID: UUID(), fileName: "b.mp4", fromFolder: "in",
                toFolder: "Bands/Ash", reason: nil),
            ReorganizePlanEntry(
                itemID: UUID(), fileName: "c.mp4", fromFolder: "in",
                toFolder: nil, reason: "no Band tag"),
            ReorganizePlanEntry(
                itemID: UUID(), fileName: "d.mp4", fromFolder: "in",
                toFolder: nil, reason: "no Band tag"),
            ReorganizePlanEntry(
                itemID: UUID(), fileName: "e.mp4", fromFolder: "in",
                toFolder: "Bands/Ember", reason: nil),
        ]
        #expect(plan.movableCount == 3)
        #expect(plan.foldersCreated.map(\.folder) == ["Bands/Ash", "Bands/Ember"])
        #expect(plan.foldersCreated.first?.count == 2)
        // Reasons aggregate; the rows themselves never disappear.
        #expect(plan.skipReasons.count == 1)
        #expect(plan.skipReasons[0].reason == "no Band tag")
        #expect(plan.skipReasons[0].count == 2)
    }

    /// An unknown token names the category and points somewhere useful.
    @Test func anUnknownTokenSaysWhichCategoryIsMissing() {
        let errors = OrganizeTemplate.validate("%Bnad/%Year", categoryNames: ["Band", "Year"])
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("\"Bnad\""))
        #expect(errors[0].message.contains("Categories & Fields"))
    }
}
