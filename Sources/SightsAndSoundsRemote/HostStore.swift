import Foundation

/// A host this Mac has been let into: where it is, and who this Mac is
/// to it.
public struct SavedHost: Codable, Equatable, Identifiable, Sendable {
    /// This Mac's device id at that host. One per pairing, so it also
    /// tells one saved host from another.
    public var id: UUID
    /// What the host called itself.
    public var name: String
    public var address: String
    public var port: UInt16
    public var pairedAt: Date
    var key: ChannelKey
    var token: Data

    /// How to reach it.
    public var endpoint: RemoteEndpoint {
        RemoteEndpoint(host: address, port: port, key: key, deviceID: id, token: token)
    }
}

/// The hosts this Mac can connect to, in a file only the user can read:
/// it holds this Mac's key and token for each.
public final class HostStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var saved: [SavedHost]

    public init(file: URL) throws {
        self.file = file
        saved = try SecretFile.read([SavedHost].self, from: file) ?? []
    }

    public var hosts: [SavedHost] { lock.withLock { saved.sorted { $0.pairedAt < $1.pairedAt } } }

    public func save(_ host: SavedHost) throws {
        try change { hosts in
            hosts.removeAll { $0.id == host.id }
            hosts.append(host)
        }
    }

    /// Forget a host. The host still has this Mac in its list until it
    /// is revoked there; what is forgotten here is the way in.
    public func remove(_ id: UUID) throws {
        try change { $0.removeAll { $0.id == id } }
    }

    /// The host has moved: a new address from its router, or a new port.
    public func move(_ id: UUID, toAddress address: String, port: UInt16) throws {
        try change { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
            hosts[index].address = address
            hosts[index].port = port
        }
    }

    private func change(_ body: (inout [SavedHost]) -> Void) throws {
        try lock.withLock {
            var next = saved
            body(&next)
            try SecretFile.write(next, to: file)
            saved = next
        }
    }
}
