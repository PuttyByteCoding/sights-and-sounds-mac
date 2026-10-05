import CryptoKit
import Foundation

/// What the host shows, once, to a Mac that is to be let in: where the
/// host is, what it is called, and a secret good for one pairing.
///
/// It is long because it has to be. The secret is the key the first
/// connection is made with, and a key short enough to type would be one
/// that could be guessed from a recorded handshake. It is meant to be
/// copied, or read off the screen as a QR code, not typed.
public struct PairingCode: Equatable, Sendable {
    /// The host's address on the local network.
    public var address: String
    public var port: UInt16
    public var hostName: String
    /// Thirty-two random bytes, the channel's key until the host has
    /// answered.
    public var secret: Data

    public static let secretLength = 32
    static let prefix = "SAS-PAIR-"
    private static let format: UInt8 = 1
    /// The name the pairing key goes by on the wire. It names the
    /// purpose, not the host or the device.
    static let identity = "pairing"

    public init(address: String, port: UInt16, hostName: String, secret: Data) {
        self.address = address
        self.port = port
        self.hostName = String(hostName.prefix(48))
        self.secret = secret
    }

    static func random(address: String, port: UInt16, hostName: String) -> PairingCode {
        PairingCode(
            address: address, port: port, hostName: hostName,
            secret: ChannelKey.random(identity: identity).key)
    }

    /// The key the first connection is made with.
    var key: ChannelKey { ChannelKey(identity: Self.identity, key: secret) }

    /// The code as text: one line, safe to paste anywhere.
    public var text: String {
        var bytes = Data([Self.format, UInt8(port >> 8), UInt8(port & 0xFF)])
        for field in [Data(address.utf8), Data(hostName.utf8)] {
            bytes.append(UInt8(min(field.count, 255)))
            bytes.append(field.prefix(255))
        }
        bytes.append(secret)
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + encoded
    }

    /// Read a code back. Nil for anything that is not exactly one: text
    /// that came from somewhere else is not given the benefit of the
    /// doubt. Spaces and line breaks around and inside it are forgiven,
    /// since that is what copying and pasting does to a long line.
    public init?(text: String) {
        let joined = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let compact = String(String.UnicodeScalarView(joined))
        guard compact.count > Self.prefix.count,
              compact.prefix(Self.prefix.count).uppercased() == Self.prefix
        else { return nil }
        var encoded = compact.dropFirst(Self.prefix.count)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let bytes = Data(base64Encoded: encoded), bytes.count >= 3, bytes[0] == Self.format else {
            return nil
        }
        let port = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        var rest = bytes.dropFirst(3)
        func field() -> String? {
            guard let length = rest.first, rest.count > Int(length) else { return nil }
            let value = String(data: rest.dropFirst().prefix(Int(length)), encoding: .utf8)
            rest = rest.dropFirst(1 + Int(length))
            return value
        }
        guard port != 0, let address = field(), let hostName = field(),
              !address.isEmpty, rest.count == Self.secretLength
        else { return nil }
        self.address = address
        self.port = port
        self.hostName = hostName
        self.secret = Data(rest)
    }

    /// What a device sends with its request to pair: that it holds the
    /// secret, said about the name it is asking under. A connection made
    /// with some other key the host holds — an approved device's own —
    /// cannot make one, and so cannot ask to be paired a second time
    /// under another name.
    static func proof(secret: Data, deviceName: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(deviceName.utf8), using: SymmetricKey(data: secret)))
    }
}
