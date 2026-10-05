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

    /// Holds whoever waits on it until it is opened.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                let held = waiting
                waiting = []
                return held
            }
            for continuation in held { continuation.resume() }
        }
    }

    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("\(what): never happened")
    }

    /// A fast scroll asks for hundreds of tiles and keeps a dozen. The
    /// ones that scrolled away before their turn came are not rendered.
    ///
    /// Each step waits for what it needs to be so, rather than for a
    /// while: the first render holds the only slot until the others have
    /// queued behind it and been given up on. It used to sleep thirty
    /// milliseconds at each step and hope, which a slow machine did not
    /// always honour.
    @Test(.timeLimit(.minutes(1)))
    func tilesThatScrolledAwayBeforeTheirTurnAreNotRendered() async throws {
        let gauge = Gauge()
        let rendering = Latch()
        defer { rendering.open() }
        let provider = ThumbnailProvider(maxConcurrent: 1) { _, _ in
            await gauge.enter()
            await rendering.wait()
            await gauge.leave()
            return Data("jpeg".utf8)
        }
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
        try await waitUntil("the first is rendering") { await gauge.started == 1 }
        let scrolledAway = (0..<5).map { _ in Task { await request() } }
        try await waitUntil("the others are queued behind it") { await provider.queuedForATurn == 5 }
        for task in scrolledAway { task.cancel() }
        try await waitUntil("the others have been given up on") { await provider.thumbnailsWaitedFor == 1 }

        rendering.open()
        await kept.value
        for task in scrolledAway { await task.value }

        #expect(await gauge.started == 1)
    }
}
