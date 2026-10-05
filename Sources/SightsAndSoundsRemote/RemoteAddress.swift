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

    /// This Mac's own addresses on a local network: what another Mac
    /// there would connect to. Wired and wireless addresses a router
    /// gave come first; an address the Mac gave itself for want of one
    /// (169.254) comes last.
    public static func ofThisMac() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isLocalNetwork(text) else { continue }
            found.append((String(cString: entry.ifa_name), text))
        }
        return found
            .sorted { a, b in
                let (selfA, selfB) = (a.address.hasPrefix("169.254."), b.address.hasPrefix("169.254."))
                return selfA == selfB ? a.interface < b.interface : !selfA
            }
            .map(\.address)
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
