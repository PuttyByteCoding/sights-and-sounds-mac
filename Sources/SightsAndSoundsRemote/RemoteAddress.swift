import Foundation

/// Which addresses a host takes a connection from: its own network, and
/// itself. A library is shared with the Macs in the house, not with
/// whatever can reach the port.
public enum RemoteAddress {
    /// True for loopback, the private IPv4 ranges (10/8, 172.16/12,
    /// 192.168/16), link-local (169.254/16, fe80::/10) and IPv6 unique
    /// local addresses (fc00::/7). Anything else, and anything that is
    /// not an address, is false.
    public static func isLocalNetwork(_ address: String) -> Bool {
        // An interface name may trail an IPv6 address: fe80::1%en0.
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        if let v4 = ipv4(bare) { return isLocal(v4) }
        guard let v6 = ipv6(bare) else { return false }
        // An IPv4 address written as IPv6: ::ffff:192.168.1.20.
        if v6[0..<10].allSatisfy({ $0 == 0 }), v6[10] == 0xFF, v6[11] == 0xFF {
            return isLocal(Array(v6[12..<16]))
        }
        if v6[0..<15].allSatisfy({ $0 == 0 }), v6[15] == 1 { return true }  // ::1
        if v6[0] & 0xFE == 0xFC { return true }  // fc00::/7
        if v6[0] == 0xFE, v6[1] & 0xC0 == 0x80 { return true }  // fe80::/10
        return false
    }

    private static func isLocal(_ v4: [UInt8]) -> Bool {
        switch (v4[0], v4[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}
