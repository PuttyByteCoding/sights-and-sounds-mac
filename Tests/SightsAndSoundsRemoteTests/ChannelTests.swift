import Foundation
import Network
import Testing

@testable import SightsAndSoundsRemote

/// The encrypted channel between two Macs, proven here between two ends
/// of one: a listener and a connection over loopback. What gets through
/// is frames, in both directions, and only for a key the listener holds.
@Suite struct ChannelTests {
    /// A listener that answers each connection's frames back to it.
    final class Echo: @unchecked Sendable {
        let listener: FrameListener
        let port: UInt16
        private let serving: Task<Void, Never>

        init(keys: [ChannelKey], accepts: @escaping @Sendable (String) -> Bool = RemoteAddress.isLocalNetwork) async throws {
            let listener = FrameListener(keys: keys, accepts: accepts)
            port = try await listener.start()
            self.listener = listener
            serving = Task {
                for await connection in listener.connections {
                    Task {
                        while let frame = try? await connection.receive() {
                            try? await connection.send(frame)
                        }
                        await connection.close()
                    }
                }
            }
        }

        func stop() {
            serving.cancel()
            listener.stop()
        }
    }

    private func connect(_ echo: Echo, _ key: ChannelKey) async throws -> FrameConnection {
        let connection = FrameConnection(host: "127.0.0.1", port: echo.port, key: key)
        try await connection.open(timeout: .seconds(5))
        return connection
    }

    @Test(.timeLimit(.minutes(1)))
    func framesCrossInBothDirections() async throws {
        let key = ChannelKey.random(identity: "device-a")
        let echo = try await Echo(keys: [key])
        defer { echo.stop() }
        let connection = try await connect(echo, key)
        defer { Task { await connection.close() } }

        for frame in [
            Frame(kind: 4, payload: Data("hello".utf8)),
            Frame(kind: 5, payload: Data()),
            // Larger than any one read: it arrives in pieces.
            Frame(kind: 9, payload: Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
        ] {
            try await connection.send(frame)
            #expect(try await connection.receive() == frame)
        }
    }

    /// Forward secrecy is the point of the suite asked for, and a suite
    /// that is not supported is replaced without a word by one that has
    /// none. So what was negotiated is checked, not assumed.
    @Test(.timeLimit(.minutes(1)))
    func theSuiteNegotiatedIsTheOneAskedFor() async throws {
        let key = ChannelKey.random(identity: "device-a")
        let echo = try await Echo(keys: [key])
        defer { echo.stop() }
        let connection = try await connect(echo, key)
        defer { Task { await connection.close() } }
        #expect(await connection.negotiatedSuite == ChannelSecurity.suite)
        #expect(ChannelSecurity.suite == 0xCCAC)
    }

    @Test(.timeLimit(.minutes(1)))
    func eachOfTheListenersKeysConnectsAndNoOtherDoes() async throws {
        let a = ChannelKey.random(identity: "device-a")
        let b = ChannelKey.random(identity: "device-b")
        let echo = try await Echo(keys: [a, b])
        defer { echo.stop() }

        for key in [a, b] {
            let connection = try await connect(echo, key)
            try await connection.send(Frame(kind: 4, payload: Data(key.identity.utf8)))
            #expect(try await connection.receive().payload == Data(key.identity.utf8))
            await connection.close()
        }

        // The right name with the wrong key.
        let forged = ChannelKey(identity: "device-a", key: ChannelKey.random(identity: "x").key)
        await #expect(throws: ChannelError.self) { _ = try await connect(echo, forged) }
        // A key the listener has, under a name it does not.
        let renamed = ChannelKey(identity: "device-z", key: a.key)
        await #expect(throws: ChannelError.self) { _ = try await connect(echo, renamed) }
    }

    /// Something that connects without the channel's encryption is told
    /// nothing: no frame, no name, no version.
    @Test(.timeLimit(.minutes(1)))
    func aClientThatDoesNotSpeakTheChannelGetsNoFrames() async throws {
        let key = ChannelKey.random(identity: "device-a")
        let echo = try await Echo(keys: [key])
        defer { echo.stop() }

        let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: echo.port)!, using: .tcp)
        let received = Received()
        plain.stateUpdateHandler = { state in
            if case .ready = state {
                let hello = try! FrameCodec.encode(Frame(kind: 4, payload: Data("hello".utf8)))
                plain.send(content: hello, completion: .contentProcessed { _ in })
                plain.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    received.set(data ?? Data())
                }
            }
        }
        plain.start(queue: .global())
        for _ in 0..<200 where received.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        plain.cancel()
        // Whatever came back, it is not the frame that was sent.
        var answer = received.value ?? Data()
        let frame = try? FrameCodec.decode(from: &answer)
        #expect(frame?.payload != Data("hello".utf8))
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ new: Data) { lock.withLock { data = new } }
        var value: Data? { lock.withLock { data } }
    }

    /// A device that is revoked has its key taken out of the listener; a
    /// device that is paired has its key put in.
    @Test(.timeLimit(.minutes(1)))
    func replacingTheKeysTurnsAwayTheOldAndTakesTheNew() async throws {
        let old = ChannelKey.random(identity: "device-old")
        let new = ChannelKey.random(identity: "device-new")
        let echo = try await Echo(keys: [old])
        defer { echo.stop() }

        try await echo.listener.replaceKeys([new])
        #expect(echo.listener.port == echo.port, "the port moved, and the client's address with it")

        let after = try await connect(echo, new)
        try await after.send(Frame(kind: 4, payload: Data("new".utf8)))
        #expect(try await after.receive().payload == Data("new".utf8))
        await after.close()
        await #expect(throws: ChannelError.self) { _ = try await connect(echo, old) }
    }

    /// Revoking a device has to end what it is doing, not only stop it
    /// starting again: a connection it already has open is closed. The
    /// listener cannot tell whose connection is whose, so every one made
    /// under the old keys goes, and a device still welcome reconnects.
    @Test(.timeLimit(.minutes(1)))
    func replacingTheKeysClosesTheConnectionsMadeUnderTheOldOnes() async throws {
        let revoked = ChannelKey.random(identity: "device-revoked")
        let kept = ChannelKey.random(identity: "device-kept")
        let echo = try await Echo(keys: [revoked, kept])
        defer { echo.stop() }
        let revokedConnection = try await connect(echo, revoked)
        let keptConnection = try await connect(echo, kept)
        // Both are in use: a frame out and back on each.
        for connection in [revokedConnection, keptConnection] {
            try await connection.send(Frame(kind: 4, payload: Data("before".utf8)))
            #expect(try await connection.receive().payload == Data("before".utf8))
        }

        try await echo.listener.replaceKeys([kept])

        // The revoked device's open connection carries nothing more.
        await #expect(throws: ChannelError.self) {
            try await revokedConnection.send(Frame(kind: 4, payload: Data("after".utf8)))
            _ = try await revokedConnection.receive()
        }
        // Nor can it make another.
        await #expect(throws: ChannelError.self) { _ = try await connect(echo, revoked) }
        // The device still welcome lost its connection too, and gets a new one.
        await #expect(throws: ChannelError.self) {
            try await keptConnection.send(Frame(kind: 4, payload: Data("after".utf8)))
            _ = try await keptConnection.receive()
        }
        let again = try await connect(echo, kept)
        try await again.send(Frame(kind: 4, payload: Data("again".utf8)))
        #expect(try await again.receive().payload == Data("again".utf8))
        await again.close()
    }

    /// Turning remote access off turns it off for whoever is connected.
    @Test(.timeLimit(.minutes(1)))
    func stoppingTheListenerClosesItsConnections() async throws {
        let key = ChannelKey.random(identity: "device-a")
        let echo = try await Echo(keys: [key])
        let connection = try await connect(echo, key)
        try await connection.send(Frame(kind: 4, payload: Data("before".utf8)))
        #expect(try await connection.receive().payload == Data("before".utf8))

        echo.stop()

        await #expect(throws: ChannelError.self) {
            try await connection.send(Frame(kind: 4, payload: Data("after".utf8)))
            _ = try await connection.receive()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAddressOutsideTheLocalNetworkIsTurnedAway() async throws {
        let key = ChannelKey.random(identity: "device-a")
        // Loopback stands in for the outside world: this listener takes
        // no address at all.
        let echo = try await Echo(keys: [key], accepts: { _ in false })
        defer { echo.stop() }
        let connection = FrameConnection(host: "127.0.0.1", port: echo.port, key: key)
        await #expect(throws: ChannelError.self) {
            try await connection.open(timeout: .seconds(3))
            try await connection.send(Frame(kind: 4, payload: Data("hello".utf8)))
            _ = try await connection.receive()
        }
    }

    /// The other end going away is an error to whoever is waiting on it,
    /// not a wait that never ends.
    @Test(.timeLimit(.minutes(1)))
    func theOtherEndClosingEndsTheWait() async throws {
        let key = ChannelKey.random(identity: "device-a")
        let listener = FrameListener(keys: [key])
        let port = try await listener.start()
        defer { listener.stop() }
        let accepted = Task { () -> FrameConnection? in
            for await connection in listener.connections { return connection }
            return nil
        }
        let client = FrameConnection(host: "127.0.0.1", port: port, key: key)
        try await client.open(timeout: .seconds(5))
        let host = try #require(await accepted.value)

        let waiting = Task { try await client.receive() }
        await host.close()
        await #expect(throws: ChannelError.self) { _ = try await waiting.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingListeningIsAnErrorSoonNotATimeout() async throws {
        // A listener that was started and stopped: its port is closed.
        let key = ChannelKey.random(identity: "device-a")
        let listener = FrameListener(keys: [key])
        let port = try await listener.start()
        listener.stop()
        try await Task.sleep(for: .milliseconds(200))

        let began = ContinuousClock.now
        let connection = FrameConnection(host: "127.0.0.1", port: port, key: key)
        await #expect(throws: ChannelError.self) { try await connection.open(timeout: .seconds(8)) }
        #expect(ContinuousClock.now - began < .seconds(6))
    }

    @Test func aKeyIsThirtyTwoRandomBytes() {
        let one = ChannelKey.random(identity: "a"), two = ChannelKey.random(identity: "a")
        #expect(one.key.count == 32 && two.key.count == 32)
        #expect(one.key != two.key)
    }
}
