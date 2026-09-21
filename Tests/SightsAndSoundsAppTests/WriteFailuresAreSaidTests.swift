import Foundation
import SightsAndSoundsKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// A write that fails must say so, and keep saying so. These used to be
/// `try?`, and the browse model's error line was wiped by the next
/// listing, which lands a fraction of a second after every write.
@Suite @MainActor struct WriteFailuresAreSaidTests {
    struct Refused: Error, CustomStringConvertible { var description: String { "the disk said no" } }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func aFailedWriteNamesWhatFailedAndWhy() {
        var text: String?
        let report = Binding(get: { text }, set: { text = $0 })

        let worked = Writes.attempt("delete the tag", report: report) { throw Refused() }

        #expect(!worked)
        #expect(text == "Could not delete the tag: the disk said no")
        #expect(Writes.attempt("delete the tag", report: report) {})
    }

    @Test func theErrorLineSurvivesTheRefreshThatFollows() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Errors")
        let source = Source(name: "S", rootPath: "/tmp/sas-errors-\(UUID().uuidString)")
        try await library.writer.write { db in
            try source.insert(db)
            try MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false).insert(db)
        }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        try await waitUntil { model.items.count == 1 }

        model.attempt("restore a.mp4") { throw Refused() }
        #expect(model.errorMessage == "Could not restore a.mp4: the disk said no")

        // A listing lands, successfully — and the error is still there.
        model.filter.searchText = "a.mp"
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.items.count == 1)
        #expect(model.errorMessage == "Could not restore a.mp4: the disk said no")
        // …and it is not the grid's problem: the listing is fine, so the
        // grid stays on screen under the banner.
        #expect(model.listingError == nil)
    }
}
