import Foundation
import SightsAndSoundsKit

/// What a host knows that the channel does not: its name, which devices
/// it has approved, and the libraries it holds.
public struct HostDirectory: Sendable {
    public var hostName: @Sendable () -> String
    /// Whether this device, with this token, is one the host has approved
    /// and not revoked. Asked on every connection.
    public var approves: @Sendable (_ deviceID: UUID, _ token: Data) async -> Bool
    public var libraries: @Sendable () async -> [RemoteLibraryInfo]
    /// The service for one of those libraries, or nil when there is none
    /// of that id.
    public var service: @Sendable (_ libraryID: UUID) async -> (any LibraryService)?
    /// Answer a Mac that asks to be approved, on the connection it asked
    /// on: a grant or a refusal, to be sent back down it. Nil for a host
    /// that pairs no one.
    public var pair: (@Sendable (_ request: PairRequest, _ connection: FrameConnection) async -> Frame)?
    /// Told each time an approved device is welcomed.
    public var greeted: @Sendable (_ deviceID: UUID) -> Void

    public init(
        hostName: @escaping @Sendable () -> String,
        approves: @escaping @Sendable (_ deviceID: UUID, _ token: Data) async -> Bool,
        libraries: @escaping @Sendable () async -> [RemoteLibraryInfo],
        service: @escaping @Sendable (_ libraryID: UUID) async -> (any LibraryService)?,
        pair: (@Sendable (_ request: PairRequest, _ connection: FrameConnection) async -> Frame)? = nil,
        greeted: @escaping @Sendable (_ deviceID: UUID) -> Void = { _ in }
    ) {
        self.hostName = hostName
        self.approves = approves
        self.libraries = libraries
        self.service = service
        self.pair = pair
        self.greeted = greeted
    }
}

/// The host's end of the conversation: for each connection the listener
/// hands out, hears who is calling, and — for a device the host has
/// approved, on a build it can talk to — answers its requests from the
/// library it asked for.
///
/// It decides nothing about the library. A request is decoded, the
/// operation of that name is called on the `LibraryService` the host's
/// own windows use, and the result is encoded.
public final class ServiceHost: @unchecked Sendable {
    private let listener: FrameListener
    private let directory: HostDirectory
    private let lock = NSLock()
    private var serving: Task<Void, Never>?
    private var sessions: [UUID: Session] = [:]

    private struct Session {
        let deviceID: UUID
        let connection: FrameConnection
    }

    public init(listener: FrameListener, directory: HostDirectory) {
        self.listener = listener
        self.directory = directory
    }

    /// Begin listening and serving. Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let port = try await listener.start()
        let listener = listener
        let task = Task { [weak self] in
            for await connection in listener.connections {
                Task { [weak self] in await self?.serve(connection) }
            }
        }
        lock.withLock { serving = task }
        return port
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = serving
            serving = nil
            sessions = [:]
            return task
        }
        task?.cancel()
        listener.stop()
    }

    /// End what a device is doing now: every connection it has open. For
    /// a device just revoked — it is refused from here on by `approves`,
    /// and this is what stops the requests already under way.
    public func closeSessions(of deviceID: UUID) {
        let open = lock.withLock { () -> [FrameConnection] in
            let mine = sessions.filter { $0.value.deviceID == deviceID }
            for key in mine.keys { sessions[key] = nil }
            return mine.values.map(\.connection)
        }
        for connection in open { Task { await connection.close() } }
    }

    /// How many connections are being served, and for how many devices.
    public var sessionCounts: (connections: Int, devices: Int) {
        lock.withLock { (sessions.count, Set(sessions.values.map(\.deviceID)).count) }
    }

    // MARK: - One connection

    private func serve(_ connection: FrameConnection) async {
        let id = UUID()
        defer {
            lock.withLock { sessions[id] = nil }
            Task { await connection.close() }
        }
        do {
            guard let (caller, service) = try await greet(connection, session: id) else { return }
            while true {
                let frame = try await connection.receive()
                // Approved when it said hello is not approved now. A
                // device revoked since is told so at its next request,
                // on a connection it already had, and gets nothing more.
                guard await directory.approves(caller.deviceID, caller.token) else {
                    try await connection.send(Self.notApproved)
                    return
                }
                switch frame.kind {
                case RemoteProtocol.Kind.request:
                    try await connection.send(await answer(frame, service))
                case RemoteProtocol.Kind.ping:
                    try await connection.send(Frame(kind: RemoteProtocol.Kind.pong))
                case RemoteProtocol.Kind.subscribe:
                    try await streamChanges(of: service, to: connection, for: caller)
                    return
                default:
                    return
                }
            }
        } catch {
            // The other end went away, or sent something unreadable:
            // either way this connection is done.
        }
    }

    private static let notApprovedRefusal = Refusal(
        .notApproved, "This Mac has not been approved by the other one.")
    private static var notApproved: Frame {
        Frame(
            kind: RemoteProtocol.Kind.refusal,
            payload: (try? RemoteProtocol.encode(notApprovedRefusal)) ?? Data())
    }

    /// Hear the hello and answer it. Returns who is calling and the
    /// service the connection is for; nil when it was refused, or asked
    /// only which libraries there are.
    private func greet(
        _ connection: FrameConnection, session: UUID
    ) async throws -> (Hello, any LibraryService)? {
        let first = try await connection.receive()
        if first.kind == RemoteProtocol.Kind.pair {
            await answerPairing(first, on: connection)
            return nil
        }
        guard first.kind == RemoteProtocol.Kind.hello else { return nil }
        let hello = try RemoteProtocol.decode(Hello.self, from: first.payload)

        func refuse(_ refusal: Refusal) async throws -> (Hello, any LibraryService)? {
            try await connection.send(
                Frame(kind: RemoteProtocol.Kind.refusal, payload: try RemoteProtocol.encode(refusal)))
            return nil
        }

        // Known as this device's from here, before it is asked about:
        // a device revoked while that question is being answered must
        // find its connection among the ones to close.
        lock.withLock { sessions[session] = Session(deviceID: hello.deviceID, connection: connection) }

        // Who it is, before anything about the host is said: a device not
        // approved learns nothing here, not even that the builds differ.
        guard await directory.approves(hello.deviceID, hello.token) else {
            return try await refuse(Self.notApprovedRefusal)
        }
        guard hello.protocolVersion == RemoteProtocol.version,
              hello.schema == LibraryDatabase.schemaIdentifier
        else {
            return try await refuse(Refusal(
                .versionMismatch,
                "The two Macs are running different versions of the app. Update the older one."))
        }
        var service: (any LibraryService)?
        if let libraryID = hello.libraryID {
            guard let found = await directory.service(libraryID) else {
                return try await refuse(Refusal(.noSuchLibrary, "The other Mac no longer has that library."))
            }
            service = found
        }
        let welcome = Welcome(hostName: directory.hostName(), libraries: await directory.libraries())
        try await connection.send(
            Frame(kind: RemoteProtocol.Kind.welcome, payload: try RemoteProtocol.encode(welcome)))
        directory.greeted(hello.deviceID)
        return service.map { (hello, $0) }
    }

    /// A Mac asking to be approved. Whatever is answered, nothing else is
    /// said on this connection.
    private func answerPairing(_ frame: Frame, on connection: FrameConnection) async {
        var reply = Self.refusal(.notPaired, "The other Mac is not pairing a device just now.")
        if let pair = directory.pair,
           let request = try? RemoteProtocol.decode(PairRequest.self, from: frame.payload) {
            reply = await pair(request, connection)
        }
        try? await connection.send(reply)
    }

    static func refusal(_ reason: Refusal.Reason, _ message: String) -> Frame {
        Frame(
            kind: RemoteProtocol.Kind.refusal,
            payload: (try? RemoteProtocol.encode(Refusal(reason, message))) ?? Data())
    }

    private func answer(_ frame: Frame, _ service: any LibraryService) async -> Frame {
        do {
            let request = try RemoteProtocol.decode(ServiceRequest.self, from: frame.payload)
            // Checked here, where the request arrives, whatever the
            // client's own code would or would not have sent.
            if let refusal = request.refusalForAnotherMac {
                return Frame(kind: RemoteProtocol.Kind.failure, payload: Data(refusal.utf8))
            }
            return RemoteProtocol.answerFrame(try await request.answer(with: service))
        } catch {
            // The library's own words for what went wrong: the client
            // shows them where the local app would.
            return Frame(kind: RemoteProtocol.Kind.failure, payload: Data("\(error)".utf8))
        }
    }

    /// Send each change of the library until the client goes away. The
    /// client sends nothing more on this connection, so its next frame —
    /// or the connection closing — is the sign to stop.
    private func streamChanges(
        of service: any LibraryService, to connection: FrameConnection, for caller: Hello
    ) async throws {
        let changes = service.changes()
        let directory = directory
        let sending = Task {
            for await change in changes {
                // Still welcome? A revoked device is not told what the
                // library is doing; its stream is closed instead.
                guard await directory.approves(caller.deviceID, caller.token) else {
                    await connection.close()
                    return
                }
                let domains = change.domains.map(\.rawValue).sorted()
                guard let payload = try? RemoteProtocol.encode(domains) else { continue }
                do {
                    try await connection.send(Frame(kind: RemoteProtocol.Kind.change, payload: payload))
                } catch {
                    return
                }
            }
        }
        defer { sending.cancel() }
        _ = try? await connection.receive()
    }
}
