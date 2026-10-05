import Foundation
import Testing

@testable import SightsAndSoundsRemote

/// The host takes a connection only from its own network.
@Suite struct RemoteAddressTests {
    @Test func privateAndLocalAddressesAreTheLocalNetwork() {
        for address in [
            "127.0.0.1", "10.0.0.7", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.20",
            "169.254.10.10", "::1", "fe80::1c2b:3aff:fe4d:5e6f", "fe80::1%en0", "fd12:3456:789a::1",
            "::ffff:192.168.1.20",
        ] {
            #expect(RemoteAddress.isLocalNetwork(address), "\(address) should be taken")
        }
    }

    @Test func everythingElseIsNot() {
        for address in [
            "8.8.8.8", "172.15.255.255", "172.32.0.1", "192.169.0.1", "11.0.0.1", "100.64.0.1",
            "2001:4860:4860::8888", "::ffff:8.8.8.8", "", "not an address", "192.168.1", "999.1.1.1",
        ] {
            #expect(!RemoteAddress.isLocalNetwork(address), "\(address) should be turned away")
        }
    }
}
