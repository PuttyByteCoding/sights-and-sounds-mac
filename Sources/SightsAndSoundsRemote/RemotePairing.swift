import Foundation

public enum PairingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The code names an address that is not on a local network.
    case notOnThisNetwork(String)
    /// No connection could be made with the code: the host is not
    /// there, or the code is no longer good.
    case unreachable(String)
    /// The host answered, and the answer was no.
    case declined(String)
    /// Nobody at the host answered the question.
    case timedOut

    public var description: String {
        switch self {
        case .notOnThisNetwork(let address):
            "The pairing code is for \(address), which is not an address on the local network."
        case .unreachable(let why):
            "The other Mac could not be reached with that code. It may have run out, or been used. (\(why))"
        case .declined(let message): message
        case .timedOut: "Nobody at the other Mac answered."
        }
    }
}

/// The client's side of pairing: take a code, ask the host, and come
/// away with this Mac's own way in.
public enum RemotePairing {
    /// Ask the host the code came from to approve this Mac. Returns when
    /// its user has answered, which is as long as that takes; cancelling
    /// the task gives up.
    ///
    /// - Parameters:
    ///   - deviceName: what the host's user is shown.
    ///   - patience: how long to wait for an answer.
    public static func pair(
        with code: PairingCode, as deviceName: String,
        patience: Duration = .seconds(660), now: Date = Date()
    ) async throws -> SavedHost {
        guard RemoteAddress.isLocalNetwork(code.address) else {
            throw PairingError.notOnThisNetwork(code.address)
        }
        let connection = FrameConnection(host: code.address, port: code.port, key: code.key)
        do {
            try await connection.open(timeout: .seconds(10))
        } catch {
            throw PairingError.unreachable("\(error)")
        }
        let outOfPatience = OneShot<Void>()
        let timer = Task {
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled else { return }
            outOfPatience.succeed(())
            await connection.close()
        }
        defer {
            timer.cancel()
            Task { await connection.close() }
        }
        do {
            let request = PairRequest(
                deviceName: deviceName, proof: PairingCode.proof(secret: code.secret, deviceName: deviceName))
            try await connection.send(
                Frame(kind: RemoteProtocol.Kind.pair, payload: try RemoteProtocol.encode(request)))
            let reply = try await connection.receive()
            switch reply.kind {
            case RemoteProtocol.Kind.grant:
                let grant = try RemoteProtocol.decode(PairGrant.self, from: reply.payload)
                guard grant.key.key.count == PairingCode.secretLength, !grant.token.isEmpty else {
                    throw ChannelError.malformed("an approval without a key")
                }
                return SavedHost(
                    id: grant.deviceID, name: grant.hostName, address: code.address, port: code.port,
                    pairedAt: now, key: grant.key, token: grant.token)
            case RemoteProtocol.Kind.refusal:
                throw PairingError.declined(try RemoteProtocol.decode(Refusal.self, from: reply.payload).message)
            default:
                throw ChannelError.malformed("a frame of kind \(reply.kind) in answer to a request to pair")
            }
        } catch let error as PairingError {
            throw error
        } catch {
            if outOfPatience.isResolved { throw PairingError.timedOut }
            throw PairingError.unreachable("\(error)")
        }
    }
}
