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

    /// Waits for `condition`, and fails the test when it never comes: a
    /// wait that timed out quietly let the checks after it pass having
    /// tested nothing.
    private func waitFor(
        _ seconds: TimeInterval = 10, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() {
            spin(0.02)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "timed out waiting", sourceLocation: sourceLocation)
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
        // One write at a time, each waited for: the hub coalesces writes that
        // land together, and three quick ones could arrive as one delivery.
        for n in 0..<3 {
            let before = model.changeCount([.items])
            try await library.writer.write {
                try MediaItem(sourceID: source.id, kind: .video, relativePath: "\(n).mp4").insert($0)
            }
            try await waitFor { model.changeCount([.items]) > before }
        }
        try await settle(0.8)
        #expect(counter.reloads == 0)
        // Fewer re-renders than deliveries: an offscreen window can be
        // asked again for reasons of its own, but not once per delivery.
        #expect(counter.bodies - bodiesAfterOpening < 3, "the window re-rendered for a domain it does not follow")

        // Its own domain: one reload, once things settle.
        try await library.writer.write { try TagCategory(name: "Band").insert($0) }
        try await waitFor { counter.reloads >= 1 }
        try await settle(0.6)
        #expect(counter.reloads == 1)
    }
    /// An import commits several times a second, and each change put the
    /// settle back: Review, Maintenance and Tag Manager did not reload until
    /// the import stopped — a mark made in the player missing from Review
    /// for the length of it. A burst now reloads within `longestSettle`.
    @Test func aSteadyStreamOfChangesStillReloads() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Stream")
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
        #expect(counter.reloads == 0)

        // Changes closer together than the plain settle, for longer than
        // `longestSettle`; each one waited for, so the hub cannot merge the
        // stream into one delivery. Only the cap can reload inside it.
        let clock = ContinuousClock()
        let started = clock.now
        let streamEnd = started + .seconds(4)
        var lastDelivered: ContinuousClock.Instant?
        var longestGap: Duration = .zero
        var n = 0
        while clock.now < streamEnd, counter.reloads == 0 {
            let before = model.changeCount([.vocabulary])
            let name = "Band \(n)"
            n += 1
            try await library.writer.write { try TagCategory(name: name).insert($0) }
            try await waitFor { model.changeCount([.vocabulary]) > before }
            let now = clock.now
            if let lastDelivered { longestGap = max(longestGap, now - lastDelivered) }
            lastDelivered = now
            try await settle(0.1)
        }
        let reloadedAfter = clock.now - started
        // Only meaningful when the machine kept up: a gap as long as the
        // plain settle lets it reload without the cap, and passing then
        // would prove nothing. (The same holds the other way: such a run
        // cannot fail.)
        if longestGap < FollowsLibraryChanges.settle {
            #expect(counter.reloads >= 1, "no reload while the changes kept coming")
            #expect(reloadedAfter < .seconds(3), "the first reload came \(reloadedAfter) into the stream")
        }
    }
}
