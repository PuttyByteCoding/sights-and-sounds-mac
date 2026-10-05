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

    public init(
        hostName: @escaping @Sendable () -> String,
        approves: @escaping @Sendable (_ deviceID: UUID, _ token: Data) async -> Bool,
        libraries: @escaping @Sendable () async -> [RemoteLibraryInfo],
        service: @escaping @Sendable (_ libraryID: UUID) async -> (any LibraryService)?
    ) {
        self.hostName = hostName
        self.approves = approves
        self.libraries = libraries
        self.service = service
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
            guard let service = try await greet(connection, session: id) else { return }
            while true {
                let frame = try await connection.receive()
                switch frame.kind {
                case RemoteProtocol.Kind.request:
                    try await connection.send(await answer(frame, service))
                case RemoteProtocol.Kind.ping:
                    try await connection.send(Frame(kind: RemoteProtocol.Kind.pong))
                case RemoteProtocol.Kind.subscribe:
                    try await streamChanges(of: service, to: connection)
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

    /// Hear the hello and answer it. Returns the service the connection
    /// is for; nil when it was refused, or asked only which libraries
    /// there are.
    private func greet(_ connection: FrameConnection, session: UUID) async throws -> (any LibraryService)? {
        let first = try await connection.receive()
        guard first.kind == RemoteProtocol.Kind.hello else { return nil }
        let hello = try RemoteProtocol.decode(Hello.self, from: first.payload)

        func refuse(_ refusal: Refusal) async throws -> (any LibraryService)? {
            try await connection.send(
                Frame(kind: RemoteProtocol.Kind.refusal, payload: try RemoteProtocol.encode(refusal)))
            return nil
        }

        // Who it is, before anything about the host is said: a device not
        // approved learns nothing here, not even that the builds differ.
        guard await directory.approves(hello.deviceID, hello.token) else {
            return try await refuse(Refusal(.notApproved, "This Mac has not been approved by the other one."))
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
        lock.withLock { sessions[session] = Session(deviceID: hello.deviceID, connection: connection) }
        let welcome = Welcome(hostName: directory.hostName(), libraries: await directory.libraries())
        try await connection.send(
            Frame(kind: RemoteProtocol.Kind.welcome, payload: try RemoteProtocol.encode(welcome)))
        return service
    }

    private func answer(_ frame: Frame, _ service: any LibraryService) async -> Frame {
        do {
            let request = try RemoteProtocol.decode(ServiceRequest.self, from: frame.payload)
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
    private func streamChanges(of service: any LibraryService, to connection: FrameConnection) async throws {
        let changes = service.changes()
        let sending = Task {
            for await change in changes {
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
