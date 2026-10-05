import Foundation
import Network

/// The host's end: listens on a port and hands out each connection that
/// completes the handshake with one of its keys, from an address it
/// takes.
public final class FrameListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var keys: [ChannelKey]
    private var boundPort: UInt16
    private let accepts: @Sendable (String) -> Bool
    private let continuation: AsyncStream<FrameConnection>.Continuation
    /// Which set of keys is current. A connection belongs to the set it
    /// was taken under.
    private var generation = 0
    /// The connections handed out and, as far as is known, still open.
    private var live: [ObjectIdentifier: Live] = [:]

    private struct Live {
        weak var connection: FrameConnection?
        let generation: Int
    }

    /// Connections, each already open: the handshake is done and the
    /// suite checked.
    public let connections: AsyncStream<FrameConnection>

    private static let queue = DispatchQueue(label: "sas.remote.listener")

    /// - Parameters:
    ///   - keys: the keys that may connect. There must be at least one:
    ///     a listener with none would not be asking for a key at all.
    ///   - port: the port to listen on, or nil for one the system picks.
    ///   - accepts: which addresses are taken; by default the local
    ///     network only.
    public init(
        keys: [ChannelKey], port: UInt16? = nil,
        accepts: @escaping @Sendable (String) -> Bool = RemoteAddress.isLocalNetwork
    ) {
        self.keys = keys
        self.boundPort = port ?? 0
        self.accepts = accepts
        (connections, continuation) = AsyncStream.makeStream(of: FrameConnection.self)
    }

    /// The port being listened on; 0 before `start`.
    public var port: UInt16 { lock.withLock { boundPort } }

    /// Begin listening. Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let (keys, port, generation) = lock.withLock { (self.keys, boundPort, self.generation) }
        let (listener, bound) = try await listen(keys: keys, port: port, generation: generation)
        lock.withLock {
            self.listener = listener
            boundPort = bound
        }
        return bound
    }

    /// Change which keys may connect: a device paired, or revoked. The
    /// listener is rebuilt on the same port.
    ///
    /// **Every connection made under the old keys is closed.** A
    /// connection does not say which key it was made with, so the
    /// listener cannot close only a revoked device's; and a revoked
    /// device left holding an open connection would not be revoked at
    /// all. A device whose key is still good finds its connection gone
    /// and makes another.
    public func replaceKeys(_ keys: [ChannelKey]) async throws {
        let (old, port, generation, stale) = lock.withLock { () -> (NWListener?, UInt16, Int, [FrameConnection]) in
            self.keys = keys
            self.generation += 1
            let old = listener
            listener = nil
            let stale = live.values.compactMap(\.connection)
            live = [:]
            return (old, boundPort, self.generation, stale)
        }
        if let old { await Self.cancel(old) }
        for connection in stale { await connection.close() }
        // The port is the client's address for this host: it must not
        // move. It can take a moment to come free.
        var lastError: (any Error)?
        for _ in 0..<20 {
            do {
                let (listener, _) = try await listen(keys: keys, port: port, generation: generation)
                lock.withLock { self.listener = listener }
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? ChannelError.refused("the port could not be listened on again")
    }

    /// Stop listening, and close every connection that was taken:
    /// turning remote access off turns it off for whoever is connected.
    public func stop() {
        let (old, open) = lock.withLock { () -> (NWListener?, [FrameConnection]) in
            generation += 1
            let old = listener
            listener = nil
            let open = live.values.compactMap(\.connection)
            live = [:]
            return (old, open)
        }
        old?.cancel()
        for connection in open { Task { await connection.close() } }
    }

    /// Hand a connection out — unless the keys have been replaced since
    /// it was taken. Its handshake may have been under way while they
    /// were, with a key that is no longer one of them.
    private func admit(_ connection: FrameConnection, takenUnder generation: Int) -> Bool {
        lock.withLock {
            guard generation == self.generation else { return false }
            live = live.filter { $0.value.connection != nil }
            live[ObjectIdentifier(connection)] = Live(connection: connection, generation: generation)
            return true
        }
    }

    private func listen(
        keys: [ChannelKey], port: UInt16, generation: Int
    ) async throws -> (NWListener, UInt16) {
        let accepts = accepts, continuation = continuation
        guard !keys.isEmpty else { throw ChannelError.refused("no key to listen with") }
        let listener = try NWListener(
            using: ChannelSecurity.parameters(keys: keys),
            on: port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any))
        listener.newConnectionHandler = { [weak self] incoming in
            guard let address = FrameConnection.address(of: incoming.endpoint), accepts(address) else {
                incoming.cancel()
                return
            }
            let connection = FrameConnection(accepted: incoming)
            Task { [weak self] in
                do {
                    try await connection.open()
                    guard let self, self.admit(connection, takenUnder: generation) else {
                        await connection.close()
                        return
                    }
                    continuation.yield(connection)
                } catch {
                    await connection.close()
                }
            }
        }
        let ready = OneShot<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.succeed(listener.port?.rawValue ?? 0)
            case .failed(let error): ready.fail(ChannelError.refused("\(error)"))
            case .cancelled: ready.fail(ChannelError.closed)
            default: break
            }
        }
        listener.start(queue: Self.queue)
        do {
            return (listener, try await ready.value)
        } catch {
            listener.cancel()
            throw error
        }
    }

    private static func cancel(_ listener: NWListener) async {
        let gone = OneShot<Void>()
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { gone.succeed(()) }
        }
        listener.cancel()
        let timer = Task {
            try? await Task.sleep(for: .seconds(2))
            gone.succeed(())
        }
        _ = try? await gone.value
        timer.cancel()
    }
}
