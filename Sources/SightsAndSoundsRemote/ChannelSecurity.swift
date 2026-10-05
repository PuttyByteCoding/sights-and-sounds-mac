import Foundation
import Network
import Security

/// A device's key for the channel: its name on the wire and thirty-two
/// random bytes. Both ends hold it; holding it is what lets a device
/// connect, and what keeps everyone else out.
public struct ChannelKey: Equatable, Sendable, Codable {
    /// Sent in the clear at the start of a connection, so the host knows
    /// which key to try. It names a key, never a person or a machine.
    public var identity: String
    public var key: Data

    public init(identity: String, key: Data) {
        self.identity = identity
        self.key = key
    }

    public static func random(identity: String) -> ChannelKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system could not supply random bytes")
        return ChannelKey(identity: identity, key: Data(bytes))
    }
}

/// How the channel is encrypted: TLS with a pre-shared key. No
/// certificate and no keychain — see
/// docs/superpowers/specs/2026-10-05-remote-library-transport.md for why
/// this app cannot use either well.
public enum ChannelSecurity {
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256: the key proves who is
    /// at each end, and a fresh exchange per connection means a key
    /// stolen later does not open traffic recorded earlier.
    public static let suite: UInt16 = 0xCCAC

    /// - Parameter resumesSessions: only ever true in a test, to stand
    ///   for a caller that asks to resume whatever this app does.
    static func parameters(keys: [ChannelKey], resumesSessions: Bool = false) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for entry in keys {
            let key = entry.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(entry.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        }
        if let ciphersuite = tls_ciphersuite_t(rawValue: suite) {
            sec_protocol_options_append_tls_ciphersuite(options, ciphersuite)
        }
        // A pre-shared key is not offered under TLS 1.3 here.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Every connection proves the key, from the start. TLS can
        // otherwise pick up where an earlier connection left off, and a
        // connection resumed is one that never showed a key at all: it
        // shows only that some connection from the same program got
        // through before. Seen on macOS 15, where a key the listener
        // did not hold connected straight after one it did. So neither
        // end keeps anything of a connection to resume it by.
        sec_protocol_options_set_tls_resumption_enabled(options, resumesSessions)
        sec_protocol_options_set_tls_tickets_enabled(options, resumesSessions)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A Mac that sleeps or loses power says nothing on its way out.
        // Without this a wait on it would never end; with it the
        // connection is found dead in about half a minute.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        // The port is not shared. A listener rebuilt with new keys comes
        // back on the same port only once the old one has let go of it:
        // with the two listening side by side, even for a moment, a
        // caller could be handed to the old one and complete a handshake
        // with a key that had just been taken away.
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// The suite a connection was actually made on. Asking for one is not
    /// getting it: a suite that is not supported is replaced, without an
    /// error, by one with no forward secrecy.
    static func negotiatedSuite(of connection: NWConnection) -> UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata
        else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }
}

/// One answer, given once, to whoever waits for it — the bridge from
/// Network.framework's callbacks, which may fire more than once and on
/// any queue.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func succeed(_ value: Value) { resolve(.success(value)) }
    func fail(_ error: any Error) { resolve(.failure(error)) }

    private func resolve(_ answer: Result<Value, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = answer
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: answer)
    }

    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}
