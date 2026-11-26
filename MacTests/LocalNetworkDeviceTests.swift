import XCTest
import Network

final class LocalNetworkDeviceTests: XCTestCase {
    func testAddressMatchingCoversLoopbackAndScopedIPv6() throws {
        let local = try ["192.168.10.4", "fe80::42%en5"].map { try XCTUnwrap(LocalNetworkDevice.Address($0)) }
        for address in ["127.0.0.2", "::1", "::ffff:127.0.0.1", "::ffff:192.168.10.4", "fe80::42%en5"] {
            XCTAssertTrue(try XCTUnwrap(LocalNetworkDevice.Address(address)).isLocal(in: local), address)
        }
        for address in ["192.168.10.5", "fe80::42%en6", "2001:db8::4"] {
            XCTAssertFalse(try XCTUnwrap(LocalNetworkDevice.Address(address)).isLocal(in: local), address)
        }
        XCTAssertTrue(LocalNetworkDevice.isLoopback(.hostPort(host: "localhost.", port: 9000)))
    }

    func testSameNameOnASecondHostIsNotTheLocalRecord() {
        let service = LocalBonjour.Service(name: "Studio", type: "_od-receiver._tcp", domain: "local.")
        let remoteLabel = LocalBonjour.Service(name: "Studio (2)", type: "_od-receiver._tcp.", domain: "local")
        let records = [service: LocalBonjour.Record(id: "local-id", port: 9000)]
        XCTAssertTrue(LocalBonjour.matches(service, id: "LOCAL-ID", in: records))
        XCTAssertTrue(LocalBonjour.matches(service, id: nil, in: records))
        XCTAssertFalse(LocalBonjour.matches(service, id: "remote-id", in: records))
        XCTAssertFalse(LocalBonjour.matches(remoteLabel, id: "remote-id", in: records))
    }
}
