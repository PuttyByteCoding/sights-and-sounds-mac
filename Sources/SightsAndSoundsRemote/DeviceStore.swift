import CryptoKit
import Foundation

/// A Mac the host has let in.
public struct ApprovedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What the device called itself when it asked.
    public var name: String
    public var approvedAt: Date
    public var lastConnectedAt: Date?
    /// Its key for the channel.
    var key: ChannelKey
    /// A hash of its token. The token itself is the device's to keep:
    /// what is here says whether one is right, and cannot be used as one.
    var tokenHash: Data
}

/// The host's record of who it has approved, in a file only the user can
/// read. Also the port the host listens on, so that it is the same port
/// tomorrow and the addresses the other Macs hold stay good.
public final class DeviceStore: @unchecked Sendable {
    private struct Contents: Codable {
        var port: UInt16?
        var devices: [ApprovedDevice] = []
    }

    private let file: URL
    private let lock = NSLock()
    private var contents: Contents

    /// Throws when the file is there and cannot be read. That is not the
    /// same as no devices, and is not treated as it.
    public init(file: URL) throws {
        self.file = file
        contents = try SecretFile.read(Contents.self, from: file) ?? Contents()
    }

    public var devices: [ApprovedDevice] {
        lock.withLock { contents.devices.sorted { $0.approvedAt < $1.approvedAt } }
    }

    public var port: UInt16? { lock.withLock { contents.port } }

    func setPort(_ port: UInt16?) throws {
        try change { $0.port = port }
    }

    var keys: [ChannelKey] { lock.withLock { contents.devices.map(\.key) } }

    /// Let a device in: it is given a key and a token of its own. The
    /// token is returned once, here, to be sent to the device, and is not
    /// kept.
    func approve(name: String, at now: Date = Date()) throws -> (device: ApprovedDevice, token: Data) {
        let id = UUID()
        let token = ChannelKey.random(identity: "token").key
        let device = ApprovedDevice(
            id: id, name: Self.presentable(name), approvedAt: now, lastConnectedAt: nil,
            key: ChannelKey.random(identity: id.uuidString), tokenHash: Self.hash(token))
        try change { $0.devices.append(device) }
        return (device, token)
    }

    /// Take a device's approval away. False when there was no such
    /// device.
    @discardableResult
    func revoke(_ id: UUID) throws -> Bool {
        var found = false
        try change { contents in
            found = contents.devices.contains { $0.id == id }
            contents.devices.removeAll { $0.id == id }
        }
        return found
    }

    /// Whether this is an approved device saying its own token.
    func approves(_ id: UUID, token: Data) -> Bool {
        let expected = lock.withLock { contents.devices.first { $0.id == id }?.tokenHash }
        guard let expected else { return false }
        return Self.same(expected, Self.hash(token))
    }

    /// Note that a device connected. Written at most once a minute for
    /// each: a device makes several connections at a time, and when it
    /// was last here does not need the second.
    @discardableResult
    func connected(_ id: UUID, at now: Date = Date()) -> Bool {
        let due = lock.withLock { () -> Bool in
            guard let last = contents.devices.first(where: { $0.id == id }) else { return false }
            return last.lastConnectedAt.map { now.timeIntervalSince($0) >= 60 } ?? true
        }
        guard due else { return false }
        try? change { contents in
            guard let index = contents.devices.firstIndex(where: { $0.id == id }) else { return }
            contents.devices[index].lastConnectedAt = now
        }
        return true
    }

    /// Change what is held and write it. If it cannot be written the
    /// change is not made: what is in memory and what is in the file do
    /// not part company.
    private func change(_ body: (inout Contents) -> Void) throws {
        try lock.withLock {
            var next = contents
            body(&next)
            try SecretFile.write(next, to: file)
            contents = next
        }
    }

    /// A name fit to show the host's user. It is the device's word for
    /// itself, so it is not trusted to be short, or one line, or there.
    static func presentable(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "A Mac with no name" : String(cleaned.prefix(64))
    }

    static func hash(_ token: Data) -> Data { Data(SHA256.hash(data: token)) }

    /// Compared without stopping at the first difference, so how long it
    /// takes says nothing about how nearly right a guess was.
    private static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
