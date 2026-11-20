import XCTest
@testable import PokeTokenBar

final class DNSSDNameTests: XCTestCase {
    func testInstanceLabelParsing() {
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "ptb-ab12cd34ef56._ptbteam._tcp.local"), "ptb-ab12cd34ef56")
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "ptb-ab12cd34ef56._ptbteam._tcp.local."), "ptb-ab12cd34ef56")
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "Ptb-AB12._PTBTEAM._TCP.LOCAL"), "Ptb-AB12")
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "민준의 맥._ptbteam._tcp.local"), "민준의 맥")
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "a.b._ptbteam._tcp.local"), "a.b")
        XCTAssertNil(DNSSDName.instanceLabel(fromPTR: "ptb-ab12._http._tcp.local"))
        XCTAssertNil(DNSSDName.instanceLabel(fromPTR: "ptb-ab12._ptbteam._udp.local"))
        XCTAssertNil(DNSSDName.instanceLabel(fromPTR: "._ptbteam._tcp.local"))
        XCTAssertNil(DNSSDName.instanceLabel(fromPTR: "_ptbteam._tcp.local"))
        XCTAssertNil(DNSSDName.instanceLabel(fromPTR: ""))
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: "x._foo._tcp.local", serviceType: "_foo._tcp"), "x")
    }

    func testFullNameRoundTrips() {
        let full = DNSSDName.fullName(instance: "ptb-ab12")
        XCTAssertEqual(full, "ptb-ab12._ptbteam._tcp.local")
        XCTAssertEqual(DNSSDName.instanceLabel(fromPTR: full), "ptb-ab12")
    }
}
