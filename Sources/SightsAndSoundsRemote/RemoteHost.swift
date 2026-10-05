import Foundation
import SightsAndSoundsKit

/// What the host's user is asked when a Mac wants in.
public struct PairingAsk: Equatable, Sendable {
    /// What the device calls itself.
    public var deviceName: String
    /// The address it called from.
    public var address: String
}

public enum RemoteHostError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRunning
    case notALocalAddress(String)

    public var description: String {
        switch self {
        case .notRunning: "Remote access is off."
        case .notALocalAddress(let address): "\(address) is not an address on the local network."
        }
    }
}

/// This Mac as a host: its libraries, offered to the Macs it has
/// approved, and the pairing by which one comes to be approved.
///
/// Nothing is advertised. A Mac finds this one by being given a pairing
/// code, which the host's user asks for and hands over.
public actor RemoteHost {
    private let store: DeviceStore
    private let hostName: @Sendable () -> String
    private let libraries: @Sendable () async -> [RemoteLibraryInfo]
    private let service: @Sendable (UUID) async -> (any LibraryService)?
    private let approve: @Sendable (PairingAsk) async -> Bool
    private let accepts: @Sendable (String) -> Bool

    /// A key no device has. A listener asks for a key by holding at
    /// least one; with this it listens — on its port, which stays its
    /// port — before any device is approved, and lets no one in.
    private let nobody = ChannelKey.random(identity: "nobody")
    private var listener: FrameListener?
    private var serving: ServiceHost?
    private var pairing: Pairing?
    private var starting: Task<UInt16, any Error>?
    /// How many times remote access has been turned off.
    private var turnedOff = 0
    private let watchers = Watchers()

    private struct Pairing {
        let id: UUID
        let code: PairingCode
        let expiry: Task<Void, Never>
        /// The host's user is being asked about a device now. The code
        /// is for one device: no second one is asked about meanwhile.
        var answering = false
    }

    /// - Parameters:
    ///   - store: who has been approved, and the port.
    ///   - approve: asks the host's user whether to let a device in.
    ///     Nothing is approved any other way.
    ///   - accepts: which addresses are taken; the local network only,
    ///     unless a test says otherwise.
    public init(
        store: DeviceStore,
        hostName: @escaping @Sendable () -> String,
        libraries: @escaping @Sendable () async -> [RemoteLibraryInfo],
        service: @escaping @Sendable (UUID) async -> (any LibraryService)?,
        approve: @escaping @Sendable (PairingAsk) async -> Bool,
        accepts: @escaping @Sendable (String) -> Bool = RemoteAddress.isLocalNetwork
    ) {
        self.store = store
        self.hostName = hostName
        self.libraries = libraries
        self.service = service
        self.approve = approve
        self.accepts = accepts
    }

    // MARK: - On and off

    public var isRunning: Bool { listener != nil }

    /// Why remote access went off by itself, if it did; cleared when it
    /// is next turned on.
    public private(set) var failure: String?

    /// The port being listened on; nil when remote access is off.
    public var port: UInt16? { listener?.port }

    /// Turn remote access on. The port is the one used last time, so the
    /// address the other Macs hold stays good; if something else has
    /// taken it this throws, and `onANewPort` asks for another — after
    /// which each paired Mac has to be told the new one.
    @discardableResult
    public func start(onANewPort: Bool = false) async throws -> UInt16 {
        if let listener { return listener.port }
        // Turned on twice at once: both wait on the one attempt.
        if let starting { return try await starting.value }
        let attempt = Task { try await self.bringUp(onANewPort: onANewPort) }
        starting = attempt
        defer { starting = nil }
        return try await attempt.value
    }

    private func bringUp(onANewPort: Bool) async throws -> UInt16 {
        let turn = turnedOff
        if onANewPort { try store.setPort(nil) }
        let listener = FrameListener(keys: keys(), port: store.port, accepts: accepts)
        let serving = ServiceHost(listener: listener, directory: directory())
        let port = try await serving.start()
        do {
            // Turned off again while it was coming up: off is what was
            // asked for last.
            guard turn == turnedOff else { throw RemoteHostError.notRunning }
            if store.port != port { try store.setPort(port) }
        } catch {
            serving.stop()
            throw error
        }
        self.listener = listener
        self.serving = serving
        failure = nil
        watchers.tell()
        return port
    }

    /// Turn remote access off: nothing listens, and whoever is connected
    /// is not any more. The approvals are kept.
    public func stop() {
        turnedOff += 1
        pairing?.expiry.cancel()
        pairing = nil
        serving?.stop()
        serving = nil
        listener = nil
        watchers.tell()
    }

    // MARK: - Devices

    public nonisolated var devices: [ApprovedDevice] { store.devices }

    /// Take a device's approval away, now: it is refused from here on,
    /// what it has open is closed, and its key is no longer one the
    /// listener holds.
    public func revoke(_ id: UUID) async throws {
        guard try store.revoke(id) else { return }
        serving?.closeSessions(of: id)
        watchers.tell()
        await rekey()
    }

    /// Fires when something a list of devices would show has changed:
    /// remote access turned on or off, a device approved, revoked or
    /// seen, a pairing begun or ended.
    public nonisolated func changes() -> AsyncStream<Void> { watchers.stream() }

    // MARK: - Pairing

    /// The code being offered, while one is.
    public var pairingCode: PairingCode? { pairing?.code }

    /// Offer to pair one device. Returns the code to hand to it: good
    /// for `lifetime`, for one device, and replacing any code offered
    /// before.
    ///
    /// - Parameter address: this Mac's address as the other Mac will
    ///   reach it; one of `RemoteAddress.ofThisMac()`.
    public func beginPairing(address: String, lifetime: Duration = .seconds(600)) async throws -> PairingCode {
        guard let listener else { throw RemoteHostError.notRunning }
        guard RemoteAddress.isLocalNetwork(address) else { throw RemoteHostError.notALocalAddress(address) }
        pairing?.expiry.cancel()
        let id = UUID()
        let code = PairingCode.random(address: address, port: listener.port, hostName: hostName())
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            await self?.expire(id)
        }
        pairing = Pairing(id: id, code: code, expiry: expiry)
        watchers.tell()
        await rekey()
        guard self.listener != nil else { throw RemoteHostError.notRunning }
        return code
    }

    /// Withdraw the code: it stops working, used or not.
    public func endPairing() async {
        guard let pairing else { return }
        pairing.expiry.cancel()
        self.pairing = nil
        watchers.tell()
        await rekey()
    }

    private func expire(_ id: UUID) async {
        // Out of time while the host's user is deciding about a device
        // that asked in time: the decision still counts, and ends the
        // code either way.
        guard let pairing, pairing.id == id, !pairing.answering else { return }
        self.pairing = nil
        watchers.tell()
        await rekey()
    }

    /// A Mac has asked to be approved, on `connection`.
    private func answer(_ request: PairRequest, on connection: FrameConnection) async -> Frame {
        let notNow = "The other Mac is not pairing a device just now. Ask it for a new pairing code."
        // Holding the secret is what makes this a request to answer. A
        // connection made with an approved device's own key reaches
        // here too, and has no proof to give.
        guard let live = pairing, !live.answering,
              request.proof == PairingCode.proof(secret: live.code.secret, deviceName: request.deviceName)
        else { return ServiceHost.refusal(.notPaired, notNow) }
        guard request.protocolVersion == RemoteProtocol.version else {
            return ServiceHost.refusal(
                .versionMismatch, "The two Macs are running different versions of the app. Update the older one.")
        }
        pairing?.answering = true
        let name = DeviceStore.presentable(request.deviceName)
        let allowed = await approve(PairingAsk(deviceName: name, address: connection.peer))

        // Withdrawn, or remote access turned off, while the question
        // was up: the answer to it no longer matters.
        guard pairing?.id == live.id else {
            return ServiceHost.refusal(
                .notPaired, "The pairing code is no longer good. Ask the other Mac for a new one.")
        }
        // Yes or no, the code has been used, and stops working here.
        live.expiry.cancel()
        pairing = nil
        var reply = ServiceHost.refusal(.notPaired, "The other Mac did not allow this one.")
        if allowed {
            do {
                let (device, token) = try store.approve(name: name)
                let grant = PairGrant(hostName: hostName(), deviceID: device.id, key: device.key, token: token)
                reply = Frame(kind: RemoteProtocol.Kind.grant, payload: try RemoteProtocol.encode(grant))
            } catch {
                reply = ServiceHost.refusal(.notPaired, "The other Mac could not record the approval: \(error)")
            }
        }
        watchers.tell()
        // The listener takes the keys as they now are — without the
        // code's, with the device's if it was let in — before the
        // device hears: what it is told it can do, it can do at once.
        // The connection being answered is the one spared.
        await rekey(keeping: connection)
        return reply
    }

    // MARK: - The listener's keys

    private func keys() -> [ChannelKey] {
        [nobody] + store.keys + (pairing.map { [$0.code.key] } ?? [])
    }

    /// Give the listener the keys as they now are. Every open connection
    /// is closed by it — the listener cannot tell whose is whose — and
    /// the devices still welcome connect again.
    ///
    /// If the listener cannot come back on its port, remote access is
    /// off, and says why: a host that looked on and was not listening
    /// would be worse.
    private func rekey(keeping: FrameConnection? = nil) async {
        guard let listener else { return }
        do {
            try await listener.replaceKeys(keys(), keeping: keeping)
        } catch {
            guard self.listener === listener else { return }
            stop()
            failure = "Remote access stopped: \(error)"
            watchers.tell()
        }
    }

    private func directory() -> HostDirectory {
        let store = store, watchers = watchers
        return HostDirectory(
            hostName: hostName,
            approves: { id, token in store.approves(id, token: token) },
            libraries: libraries,
            service: service,
            pair: { [weak self] request, connection in
                await self?.answer(request, on: connection)
                    ?? ServiceHost.refusal(.notPaired, "The other Mac is not pairing a device just now.")
            },
            greeted: { id in
                if store.connected(id) { watchers.tell() }
            })
    }
}

/// Whoever is watching a host for changes.
private final class Watchers: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func stream() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.continuations[id] = nil }
        }
        return stream
    }

    func tell() {
        let all = lock.withLock { Array(continuations.values) }
        for continuation in all { continuation.yield() }
    }
}
