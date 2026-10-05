import Foundation
import SightsAndSoundsKit

/// How to reach a host, and who this Mac is to it.
public struct RemoteEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    /// This device's key for the channel.
    public var key: ChannelKey
    public var deviceID: UUID
    public var token: Data

    public init(host: String, port: UInt16, key: ChannelKey, deviceID: UUID, token: Data) {
        self.host = host
        self.port = port
        self.key = key
        self.deviceID = deviceID
        self.token = token
    }
}

/// The client's connections to one host, for one library.
///
/// A connection carries one request at a time, so there is a small pool
/// of them. One that has sat idle is tried with a ping before it is
/// trusted with a request: the host may have closed it — it closes them
/// all when a device is paired or revoked — and a request sent down a
/// dead connection is a request that may or may not have been carried
/// out.
actor RemoteClient {
    let endpoint: RemoteEndpoint
    let libraryID: UUID?
    private let hello: Hello
    private let connectTimeout: Duration

    private struct Idle {
        let connection: FrameConnection
        let since: ContinuousClock.Instant
    }
    private var idle: [Idle] = []
    private var open = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    /// More than this many at once wait their turn.
    static let limit = 6
    /// Idle longer than this, a connection is pinged before it is used.
    static let trustedIdle: Duration = .seconds(2)

    init(endpoint: RemoteEndpoint, libraryID: UUID?, hello: Hello? = nil, connectTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.libraryID = libraryID
        self.hello = hello ?? Hello(deviceID: endpoint.deviceID, token: endpoint.token, libraryID: libraryID)
        self.connectTimeout = connectTimeout
    }

    /// A new connection, greeted. Throws `RemoteError`.
    func connect() async throws -> (FrameConnection, Welcome) {
        let connection = FrameConnection(host: endpoint.host, port: endpoint.port, key: endpoint.key)
        do {
            try await connection.open(timeout: connectTimeout)
            try await connection.send(
                Frame(kind: RemoteProtocol.Kind.hello, payload: try RemoteProtocol.encode(hello)))
            let reply = try await connection.receive()
            switch reply.kind {
            case RemoteProtocol.Kind.welcome:
                return (connection, try RemoteProtocol.decode(Welcome.self, from: reply.payload))
            case RemoteProtocol.Kind.refusal:
                throw RemoteError.refused(try RemoteProtocol.decode(Refusal.self, from: reply.payload))
            default:
                throw ChannelError.malformed("a frame of kind \(reply.kind) in answer to a hello")
            }
        } catch {
            await connection.close()
            throw Self.remote(error)
        }
    }

    /// One request, and the JSON of its answer.
    func send(_ request: ServiceRequest) async throws -> Data {
        let payload = try RemoteProtocol.encode(request)
        do {
            // A request that changes the library goes only down a
            // connection just seen to be alive: it cannot be asked again
            // if its connection turns out to have been dead.
            return try await attempt(payload, onAProvenConnection: !request.onlyReads)
        } catch let error as RemoteError {
            // Only a request that changes nothing is asked a second
            // time, and only when the host was not heard from: one it
            // answered with a failure has been answered.
            guard request.onlyReads, case .unreachable = error, !closed else { throw error }
            return try await attempt(payload, onAProvenConnection: true)
        }
    }

    private func attempt(_ payload: Data, onAProvenConnection proven: Bool) async throws -> Data {
        let connection = try await checkOut(proven: proven)
        do {
            try await connection.send(Frame(kind: RemoteProtocol.Kind.request, payload: payload))
            let reply = try await connection.receive()
            if reply.kind == RemoteProtocol.Kind.failure {
                checkIn(connection)
                throw RemoteError.failed(String(decoding: reply.payload, as: UTF8.self))
            }
            if reply.kind == RemoteProtocol.Kind.refusal {
                // Welcome when the connection was made, not any more.
                throw RemoteError.refused(try RemoteProtocol.decode(Refusal.self, from: reply.payload))
            }
            let json = try RemoteProtocol.answerJSON(reply)
            checkIn(connection)
            return json
        } catch let error as RemoteError {
            if case .failed = error { throw error }
            await discard(connection)
            throw error
        } catch {
            await discard(connection)
            throw Self.remote(error)
        }
    }

    // MARK: - The pool

    /// A connection to send one request down. `proven` asks that one
    /// taken from the pool be pinged first however lately it was used.
    private func checkOut(proven: Bool) async throws -> FrameConnection {
        while true {
            if closed { throw RemoteError.unreachable("the connection to the other Mac was closed") }
            while let candidate = idle.popLast() {
                if !proven, ContinuousClock.now - candidate.since < Self.trustedIdle {
                    return candidate.connection
                }
                if await answersPing(candidate.connection) { return candidate.connection }
                await discard(candidate.connection)
            }
            if open < Self.limit {
                open += 1
                do {
                    return try await connect().0
                } catch {
                    open -= 1
                    wakeOne()
                    throw error
                }
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func answersPing(_ connection: FrameConnection) async -> Bool {
        do {
            try await connection.send(Frame(kind: RemoteProtocol.Kind.ping))
            return try await connection.receive().kind == RemoteProtocol.Kind.pong
        } catch {
            return false
        }
    }

    private func checkIn(_ connection: FrameConnection) {
        guard !closed else {
            Task { await connection.close() }
            open -= 1
            return
        }
        idle.append(Idle(connection: connection, since: .now))
        wakeOne()
    }

    private func discard(_ connection: FrameConnection) async {
        await connection.close()
        open -= 1
        wakeOne()
    }

    private func wakeOne() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    func close() {
        closed = true
        for entry in idle { Task { await entry.connection.close() } }
        open -= idle.count
        idle = []
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// The channel's and the protocol's errors, as the one kind the
    /// client's callers meet.
    static func remote(_ error: any Error) -> RemoteError {
        switch error {
        case let error as RemoteError: error
        case let error as ChannelError: .unreachable(error.description)
        default: .unreachable("\(error)")
        }
    }
}
