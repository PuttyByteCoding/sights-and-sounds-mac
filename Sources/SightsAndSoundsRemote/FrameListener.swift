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
        let (keys, port) = lock.withLock { (self.keys, boundPort) }
        let (listener, bound) = try await Self.listen(
            keys: keys, port: port, accepts: accepts, continuation: continuation)
        lock.withLock {
            self.listener = listener
            boundPort = bound
        }
        return bound
    }

    /// Change which keys may connect: a device paired, or revoked. The
    /// listener is rebuilt on the same port. Connections already made are
    /// not touched by this; whoever holds them closes the ones that
    /// should not go on.
    public func replaceKeys(_ keys: [ChannelKey]) async throws {
        let (old, port) = lock.withLock { () -> (NWListener?, UInt16) in
            self.keys = keys
            let old = listener
            listener = nil
            return (old, boundPort)
        }
        if let old { await Self.cancel(old) }
        // The port is the client's address for this host: it must not
        // move. It can take a moment to come free.
        var lastError: (any Error)?
        for _ in 0..<20 {
            do {
                let (listener, _) = try await Self.listen(
                    keys: keys, port: port, accepts: accepts, continuation: continuation)
                lock.withLock { self.listener = listener }
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? ChannelError.refused("the port could not be listened on again")
    }

    public func stop() {
        let old = lock.withLock { () -> NWListener? in
            let old = listener
            listener = nil
            return old
        }
        old?.cancel()
    }

    private static func listen(
        keys: [ChannelKey], port: UInt16, accepts: @escaping @Sendable (String) -> Bool,
        continuation: AsyncStream<FrameConnection>.Continuation
    ) async throws -> (NWListener, UInt16) {
        guard !keys.isEmpty else { throw ChannelError.refused("no key to listen with") }
        let listener = try NWListener(
            using: ChannelSecurity.parameters(keys: keys),
            on: port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any))
        listener.newConnectionHandler = { incoming in
            guard let address = FrameConnection.address(of: incoming.endpoint), accepts(address) else {
                incoming.cancel()
                return
            }
            let connection = FrameConnection(accepted: incoming)
            Task {
                do {
                    try await connection.open()
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
        listener.start(queue: queue)
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
