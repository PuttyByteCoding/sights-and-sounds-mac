import AppKit
import Foundation
import SightsAndSoundsKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// The modifier that makes Tag Manager, Review, Maintenance and Organise
/// follow writes made elsewhere, hosted for real: opening is not a change,
/// a write in a followed domain reloads once, and a write in any other
/// domain neither reloads nor re-renders the window — reading the count in
/// the window's own body re-rendered it on every delivery in any domain.
@Suite(.serialized) @MainActor struct FollowsLibraryChangesTests {
    final class Counter {
        var bodies = 0
        var reloads = 0
    }

    struct Probe: View {
        let model: BrowseModel
        let counter: Counter
        var body: some View {
            counter.bodies += 1
            return Color.clear
                .frame(width: 40, height: 40)
                .followsLibraryChanges(model, [.vocabulary]) { counter.reloads += 1 }
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Let SwiftUI (run loop) and the main actor (awaits) both take turns.
    private func settle(_ seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin(0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitFor(_ seconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() {
            spin(0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func reloadsOnItsDomainsOnlyAndLeavesTheWindowAlone() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Follow")
        let source = Source(name: "S", rootPath: FileManager.default.temporaryDirectory.path)
        try await library.writer.write { try source.insert($0) }
        let model = BrowseModel(libraryID: UUID(), library: library, runner: JobRunner(library: library))
        let counter = Counter()
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 40, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Probe(model: model, counter: counter))
        window.orderFront(nil)
        defer { window.close() }
        try await settle(1.0)
        #expect(counter.reloads == 0, "opening is not a change")
        let bodiesAfterOpening = counter.bodies

        // Another domain: no reload, and the window's body is not asked again.
        for n in 0..<3 {
            try await library.writer.write {
                try MediaItem(sourceID: source.id, kind: .video, relativePath: "\(n).mp4").insert($0)
            }
        }
        try await waitFor { model.changeCount([.items]) >= 3 }
        try await settle(0.8)
        #expect(counter.reloads == 0)
        #expect(counter.bodies == bodiesAfterOpening, "the window re-rendered for a domain it does not follow")

        // Its own domain: one reload, once things settle.
        try await library.writer.write { try TagCategory(name: "Band").insert($0) }
        try await waitFor { counter.reloads >= 1 }
        try await settle(0.6)
        #expect(counter.reloads == 1)
    }
}
