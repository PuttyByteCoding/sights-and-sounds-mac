import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The grid asks for a thumbnail per tile as tiles scroll past. What that
/// costs when the thumbnail already exists, and what happens to requests
/// for tiles that have already scrolled away, is the whole difference
/// between a grid that scrolls and one that stutters.
@Suite struct ThumbnailProviderTests {

    /// Counts how many renders are under way and how many ever started.
    private actor Gauge {
        private(set) var started = 0
        private(set) var peak = 0
        private var inside = 0
        func enter() { started += 1; inside += 1; peak = max(peak, inside) }
        func leave() { inside -= 1 }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private func slowProvider(_ gauge: Gauge, maxConcurrent: Int) -> ThumbnailProvider {
        ThumbnailProvider(maxConcurrent: maxConcurrent) { _, _ in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(150))
            await gauge.leave()
            return Data("jpeg".utf8)
        }
    }

    /// Once a thumbnail is on disk the file it came from is irrelevant —
    /// that is what keeps an offline source looking complete — so nothing
    /// should go and work out where that file is. It used to be resolved
    /// for every tile, on the main thread, before the cache was consulted.
    @Test func aCachedThumbnailNeverAsksWhereTheFileIs() async throws {
        let libraryID = UUID(), itemID = UUID()
        let cached = ThumbnailStore.url(libraryID: libraryID, itemID: itemID)
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cached.deletingLastPathComponent()) }
        try Data("on disk".utf8).write(to: cached)
        let asked = Flag()
        let provider = ThumbnailProvider(maxConcurrent: 2) { _, _ in nil }

        let data = await provider.thumbnailData(
            itemID: itemID, libraryID: libraryID, durationSeconds: nil,
            resolveFile: { asked.set(); return nil })

        #expect(data == Data("on disk".utf8))
        #expect(!asked.isSet)
    }

    @Test func onlySoManyRenderAtOnce() async throws {
        let gauge = Gauge()
        let provider = slowProvider(gauge, maxConcurrent: 2)
        let libraryID = UUID()
        defer {
            try? FileManager.default.removeItem(
                at: ThumbnailStore.root.appendingPathComponent(libraryID.uuidString))
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = await provider.thumbnailData(
                        itemID: UUID(), libraryID: libraryID, durationSeconds: nil,
                        resolveFile: { URL(fileURLWithPath: "/tmp/sas-thumb-source.mp4") })
                }
            }
        }

        #expect(await gauge.started == 6)
        #expect(await gauge.peak <= 2)
    }

    /// A fast scroll asks for hundreds of tiles and keeps a dozen. The
    /// ones that scrolled away before their turn came are not rendered.
    @Test func tilesThatScrolledAwayBeforeTheirTurnAreNotRendered() async throws {
        let gauge = Gauge()
        let provider = slowProvider(gauge, maxConcurrent: 1)
        let libraryID = UUID()
        defer {
            try? FileManager.default.removeItem(
                at: ThumbnailStore.root.appendingPathComponent(libraryID.uuidString))
        }
        let request: @Sendable () async -> Void = {
            _ = await provider.thumbnailData(
                itemID: UUID(), libraryID: libraryID, durationSeconds: nil,
                resolveFile: { URL(fileURLWithPath: "/tmp/sas-thumb-source.mp4") })
        }

        let kept = Task { await request() }
        try await Task.sleep(for: .milliseconds(30))  // the first is rendering
        let scrolledAway = (0..<5).map { _ in Task { await request() } }
        try await Task.sleep(for: .milliseconds(30))  // they are queued behind it
        for task in scrolledAway { task.cancel() }

        await kept.value
        for task in scrolledAway { await task.value }

        #expect(await gauge.started == 1)
    }
}
