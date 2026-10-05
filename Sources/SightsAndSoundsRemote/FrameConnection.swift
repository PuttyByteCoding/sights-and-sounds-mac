import Foundation
import Network

/// One encrypted connection between two Macs, carrying frames.
///
/// One caller reads at a time and one writes at a time: a connection
/// carries one request and its answer, then the next.
public actor FrameConnection {
    private let connection: NWConnection
    private var buffer = Data()
    /// Who is at the other end, as an address.
    public nonisolated let peer: String

    private static let queue = DispatchQueue(label: "sas.remote.connection", attributes: .concurrent)

    /// A connection to a host, to be opened.
    public init(host: String, port: UInt16, key: ChannelKey) {
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: ChannelSecurity.parameters(keys: [key]))
        peer = "\(host):\(port)"
    }

    /// A connection from a caller that asks to resume an earlier one —
    /// which this app never does, and a host has to refuse all the same.
    init(resuming host: String, port: UInt16, key: ChannelKey) {
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: ChannelSecurity.parameters(keys: [key], resumesSessions: true))
        peer = "\(host):\(port)"
    }

    /// A connection a listener took, to be opened.
    init(accepted connection: NWConnection) {
        self.connection = connection
        peer = Self.address(of: connection.endpoint) ?? "\(connection.endpoint)"
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Make the connection: the handshake, and the check that it was made
    /// on the suite asked for. Throws `ChannelError.refused` when the
    /// other end will not have it — nothing listening, or not this key.
    public func open(timeout: Duration = .seconds(10)) async throws {
        let ready = OneShot<Void>()
        let connection = connection
        let retries = Retries()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.succeed(())
            case .failed(let error):
                ready.fail(ChannelError.refused("\(error)"))
            case .waiting(let error):
                // One kind of waiting is worth another try: the system
                // picked a local port for this connection that is still
                // spoken for, by one just closed. The next pick is a
                // different port. Left as a failure it turned up about
                // once in forty runs of the tests, as "address already
                // in use" from a connection that was only being made.
                if Self.isWorthAnotherTry(error), retries.takeOne() {
                    Self.queue.asyncAfter(deadline: .now() + .milliseconds(25)) { connection.restart() }
                    return
                }
                // Anything else here would only fail again. It is where
                // a key the other end does not hold shows up — the
                // handshake fails and the connection waits — and where
                // nothing listening does.
                ready.fail(ChannelError.refused("\(error)"))
            case .cancelled:
                ready.fail(ChannelError.closed)
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        let timer = Task {
            try? await Task.sleep(for: timeout)
            ready.fail(ChannelError.timedOut)
        }
        defer { timer.cancel() }
        do {
            try await ready.value
        } catch {
            connection.cancel()
            throw error
        }
        let suite = ChannelSecurity.negotiatedSuite(of: connection)
        guard suite == ChannelSecurity.suite else {
            connection.cancel()
            throw ChannelError.weakSuite(suite)
        }
    }

    /// Whether a connection that could not be made failed for a reason
    /// that is gone a moment later: no local address to make it from
    /// just then. Not a refusal by the other end, and not a failed
    /// handshake — those are answers.
    static func isWorthAnotherTry(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EADDRINUSE || code == .EADDRNOTAVAIL
    }

    /// How many more times a connection is tried. A few: a collision is
    /// over at the next pick, and something that keeps happening is not
    /// a collision.
    private final class Retries: @unchecked Sendable {
        private let lock = NSLock()
        private var left = 5
        func takeOne() -> Bool {
            lock.withLock {
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
    }

    /// The suite this connection was made on.
    public var negotiatedSuite: UInt16? { ChannelSecurity.negotiatedSuite(of: connection) }

    public func send(_ frame: Frame) async throws {
        let data = try FrameCodec.encode(frame)
        let sent = OneShot<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                sent.fail(ChannelError.broken("\(error)"))
            } else {
                sent.succeed(())
            }
        })
        try await sent.value
    }

    /// The next frame. Throws `ChannelError.closed` when the other end
    /// has gone away.
    public func receive() async throws -> Frame {
        while true {
            if let frame = try FrameCodec.decode(from: &buffer) { return frame }
            buffer.append(try await read())
        }
    }

    private func read() async throws -> Data {
        let chunk = OneShot<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, _, error in
            if let data, !data.isEmpty {
                chunk.succeed(data)
            } else if let error {
                chunk.fail(ChannelError.broken("\(error)"))
            } else {
                chunk.fail(ChannelError.closed)
            }
        }
        let connection = connection
        return try await withTaskCancellationHandler {
            try await chunk.value
        } onCancel: {
            // Whoever was waiting has stopped: the connection is of no
            // more use, and cancelling it is what ends the read.
            connection.cancel()
        }
    }

    public func close() {
        connection.cancel()
    }
}
