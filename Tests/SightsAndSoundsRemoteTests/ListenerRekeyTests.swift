import Foundation
import Testing

@testable import SightsAndSoundsRemote

/// The listener's keys changed from more than one place at once, as a
/// host does when a device is revoked while another is being paired.
@Suite struct ListenerRekeyTests {
    private func connects(_ key: ChannelKey, port: UInt16) async -> Bool {
        let connection = FrameConnection(host: "127.0.0.1", port: port, key: key)
        defer { Task { await connection.close() } }
        return (try? await connection.open(timeout: .seconds(3))) != nil
    }

    /// However many changes arrive together, the listener ends up
    /// listening, on its port, with one set of keys — the last asked
    /// for — and with nothing left over still holding an earlier set.
    @Test(.timeLimit(.minutes(2)))
    func keysReplacedAllAtOnceEndAsOneSetOfKeys() async throws {
        let first = ChannelKey.random(identity: "device-first")
        let listener = FrameListener(keys: [first])
        let port = try await listener.start()
        defer { listener.stop() }

        for round in 1...4 {
            let keys = (0..<4).map { ChannelKey.random(identity: "device-\(round)-\($0)") }
            await withTaskGroup(of: Void.self) { group in
                for key in keys {
                    group.addTask { try? await listener.replaceKeys([key]) }
                }
            }
            #expect(listener.port == port)
            var welcomed = 0
            for key in keys where await connects(key, port: port) { welcomed += 1 }
            #expect(welcomed == 1, "round \(round): \(welcomed) of the four keys connect")
            #expect(await connects(first, port: port) == false)
        }
    }

    /// Stopped while its keys were being replaced, it is stopped: the
    /// replacement does not bring it back.
    @Test(.timeLimit(.minutes(2)))
    func stoppedWhileItsKeysAreReplacedItStaysStopped() async throws {
        for _ in 1...6 {
            let old = ChannelKey.random(identity: "device-old")
            let new = ChannelKey.random(identity: "device-new")
            let listener = FrameListener(keys: [old])
            let port = try await listener.start()

            let replacing = Task { try? await listener.replaceKeys([new]) }
            listener.stop()
            await replacing.value
            try await Task.sleep(for: .milliseconds(50))

            #expect(await connects(new, port: port) == false)
            #expect(await connects(old, port: port) == false)
        }
    }
}
