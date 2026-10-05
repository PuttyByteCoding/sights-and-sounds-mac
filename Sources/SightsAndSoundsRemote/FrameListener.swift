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
    private enum Phase { case idle, listening, stopped }
    private var phase = Phase.idle
    /// The connections handed out and, as far as is known, still open.
    private var live: [ObjectIdentifier: Live] = [:]

    private struct Live {
        weak var connection: FrameConnection?
        let generation: Int
    }

    /// How many handshakes have completed here: those handed out, and
    /// those dropped because the keys had been replaced while they were
    /// under way.
    private var counts = (admitted: 0, stale: 0)
    var handshakes: (admitted: Int, stale: Int) { lock.withLock { counts } }

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
    ///
    /// A port that was asked for by number is tried for a couple of
    /// seconds before it is given up on: the last listener to hold it —
    /// remote access turned off a moment ago, or the app as it was
    /// before it was relaunched — takes a moment to let go.
    @discardableResult
    public func start() async throws -> UInt16 {
        let (keys, port, generation, stopped) = lock.withLock {
            (self.keys, boundPort, self.generation, phase == .stopped)
        }
        guard !stopped else { throw ChannelError.closed }
        var lastError: (any Error)?
        for attempt in 0..<(port == 0 ? 1 : 20) {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard lock.withLock({ self.generation == generation }) else { throw ChannelError.closed }
            do {
                let (listener, bound) = try await listen(keys: keys, port: port, generation: generation)
                let current = lock.withLock { () -> Bool in
                    guard self.generation == generation else { return false }
                    self.listener = listener
                    boundPort = bound
                    phase = .listening
                    return true
                }
                guard current else {
                    // Stopped while it was starting.
                    await Self.cancel(listener)
                    throw ChannelError.closed
                }
                return bound
            } catch ChannelError.closed {
                throw ChannelError.closed
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ChannelError.refused("the port could not be listened on")
    }

    /// Change which keys may connect: a device paired, or revoked. The
    /// listener is rebuilt on the same port.
    ///
    /// **Every connection made under the old keys is closed** — but for
    /// `keeping`, the one connection the caller is in the middle of
    /// answering. A connection does not say which key it was made with,
    /// so the listener cannot close only a revoked device's; and a
    /// revoked device left holding an open connection would not be
    /// revoked at all. A device whose key is still good finds its
    /// connection gone and makes another.
    ///
    /// Before `start`, the keys are only noted; after `stop`, nothing
    /// is done. A change of keys does not turn a listener on.
    public func replaceKeys(_ keys: [ChannelKey], keeping: FrameConnection? = nil) async throws {
        let plan = lock.withLock { () -> (NWListener?, UInt16, Int, [FrameConnection])? in
            self.keys = keys
            guard phase == .listening else { return nil }
            self.generation += 1
            let old = listener
            listener = nil
            let stale = live.values.compactMap(\.connection).filter { $0 !== keeping }
            live = [:]
            if let keeping {
                live[ObjectIdentifier(keeping)] = Live(connection: keeping, generation: self.generation)
            }
            return (old, boundPort, self.generation, stale)
        }
        guard let (old, port, generation, stale) = plan else { return }
        if let old { await Self.cancel(old) }
        for connection in stale { await connection.close() }
        // The port is the client's address for this host: it must not
        // move. It is not shared, so it cannot be listened on again until
        // the old listener has let go of it, which takes a moment.
        var lastError: (any Error)?
        for _ in 0..<50 {
            // Overtaken — the keys replaced again, or the listener
            // stopped — while this was waiting for the port: whoever
            // overtook it has the say now.
            guard lock.withLock({ self.generation == generation }) else { return }
            do {
                let (listener, _) = try await listen(keys: keys, port: port, generation: generation)
                let current = lock.withLock { () -> Bool in
                    guard self.generation == generation else { return false }
                    self.listener = listener
                    return true
                }
                // Overtaken while it was starting: it holds keys that
                // are no longer the keys, and must not be left
                // listening with them.
                if !current { await Self.cancel(listener) }
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? ChannelError.refused("the port could not be listened on again")
    }

    /// Stop listening, for good, and close every connection that was
    /// taken: turning remote access off turns it off for whoever is
    /// connected. A listener that has been stopped is not started
    /// again; another is made.
    public func stop() {
        let (old, open) = lock.withLock { () -> (NWListener?, [FrameConnection]) in
            generation += 1
            phase = .stopped
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
            guard generation == self.generation else {
                counts.stale += 1
                return false
            }
            counts.admitted += 1
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
