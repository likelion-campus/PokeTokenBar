#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Loopback on one runner: these prove the `windns` API usage (register, browse, resolve, cancel), not LAN interop.
@MainActor
final class WindowsDNSSDTests: XCTestCase {
    @MainActor private final class Recorder {
        var events: [WinDNSSD.Event] = []
        var addresses: [WinSocketAddress]?
        var found: [String] { events.compactMap { if case .found(let n) = $0 { n } else { nil } } }
        var lost: [String] { events.compactMap { if case .lost(let n) = $0 { n } else { nil } } }
    }

    private func uniqueName(_ prefix: String = "ptb-t") -> String {
        prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func makeBrowser(_ recorder: Recorder) -> WinDNSSD {
        WinDNSSD(deliver: { recorder.events.append($0) })
    }

    func testRegisterThenBrowseFindsOurOwnInstance() async {
        let name = uniqueName()
        let advert = Recorder(), seen = Recorder()
        let registrar = makeBrowser(advert), browser = makeBrowser(seen)
        defer { registrar.deregister(); browser.stopBrowsing() }
        browser.browse()
        registrar.register(instance: name, port: 45123)
        let registered = await waitUntil(30) { advert.events.contains(.registered(name)) }
        XCTAssertTrue(registered, "no .registered(\(name)); events \(advert.events)")
        let found = await waitUntil(30) { seen.found.contains(name) }
        XCTAssertTrue(found, "browse never found \(name); events \(seen.events)")
    }

    func testResolveReturnsTheListenerPort() async {
        let name = uniqueName()
        let advert = Recorder(), seen = Recorder(), result = Recorder()
        let registrar = makeBrowser(advert), browser = makeBrowser(seen), resolver = makeBrowser(result)
        defer { registrar.deregister(); browser.stopBrowsing() }
        browser.browse()
        registrar.register(instance: name, port: 45124)
        let found = await waitUntil(30) { seen.found.contains(name) }
        XCTAssertTrue(found, "browse never found \(name); events \(seen.events)")
        resolver.resolve(instance: name) { result.addresses = $0 }
        let answered = await waitUntil(30) { result.addresses != nil }
        XCTAssertTrue(answered, "resolve never answered")
        let addresses = result.addresses ?? []
        print("DNSSD-REPORT resolve \(name) -> \(addresses)")
        XCTAssertFalse(addresses.isEmpty, "resolve gave no address")
        XCTAssertTrue(addresses.allSatisfy { $0.port == 45124 }, "\(addresses)")
        XCTAssertTrue(addresses.allSatisfy { $0.interfaceIndex != 0 }, "the interface index a link-local dial needs: \(addresses)")
        if let firstV6 = addresses.firstIndex(where: { $0.family == .ipv6 }) {
            XCTAssertTrue(addresses[..<firstV6].allSatisfy { $0.family == .ipv4 }, "IPv4 must come first: \(addresses)")
        }
    }

    /// Windows repeats browse answers (four in a row, and a steady stream while other browsers query); only changes
    /// reach the main thread.
    func testRepeatedBrowseAnswersAreDroppedAndChangesPass() async {
        var known = Set<String>()
        let first: [WinDNSSD.Event] = [.found("a"), .found("a"), .found("b"), .found("a")]
        XCTAssertEqual(WinDNSSD.changes(first, known: &known), [.found("a"), .found("b")])
        XCTAssertEqual(WinDNSSD.changes([.found("b"), .lost("c")], known: &known), [], "a repeat, and a loss of a name never found")
        XCTAssertEqual(WinDNSSD.changes([.lost("a"), .lost("a"), .found("a"), .browseFailed(5)], known: &known),
                       [.lost("a"), .found("a"), .browseFailed(5)], "found after lost is a change; failures always pass")
        XCTAssertEqual(known, ["a", "b"])
    }

    func testResolveOfAnUnknownNameReturnsEmpty() async {
        let result = Recorder()
        let resolver = makeBrowser(Recorder())
        resolver.resolve(instance: uniqueName("ptb-nobody")) { result.addresses = $0 }
        let answered = await waitUntil(WinDNSSD.resolveTimeout + 15) { result.addresses != nil }
        XCTAssertTrue(answered, "resolve of an unknown name never completed")
        XCTAssertEqual(result.addresses ?? [WinSocketAddress(family: .ipv4, host: "x", port: 0)], [])
    }

    func testTwoInstancesWithDifferentNamesAreBothFound() async {
        let a = uniqueName("ptb-a"), b = uniqueName("ptb-b")
        let seen = Recorder()
        let first = makeBrowser(Recorder()), second = makeBrowser(Recorder()), browser = makeBrowser(seen)
        defer { first.deregister(); second.deregister(); browser.stopBrowsing() }
        browser.browse()
        first.register(instance: a, port: 45125)
        second.register(instance: b, port: 45126)
        let both = await waitUntil(40) { seen.found.contains(a) && seen.found.contains(b) }
        XCTAssertTrue(both, "found \(seen.found), wanted \(a) and \(b)")
    }

    func testDeregisterThenBrowseReportsWhatWindowsSaysOnRemoval() async {
        let name = uniqueName()
        let seen = Recorder()
        let registrar = makeBrowser(Recorder()), browser = makeBrowser(seen)
        defer { registrar.deregister(); browser.stopBrowsing() }
        browser.browse()
        registrar.register(instance: name, port: 45127)
        let found = await waitUntil(30) { seen.found.contains(name) }
        XCTAssertTrue(found, "browse never found \(name); events \(seen.events)")
        let before = seen.events.count
        let start = Date()
        registrar.deregister()
        let lost = await waitUntil(60) { seen.lost.contains(name) }
        let after = Array(seen.events[before...])
        print("DNSSD-REPORT removal of \(name): .lost \(lost ? "arrived after \(Int(Date().timeIntervalSince(start) * 1000)) ms" : "did NOT arrive within 60 s"); events since deregister: \(after)")
        // Not asserted either way: this test exists to record the behaviour (the plan's F13). A stale-forever
        // entry is a finding, not a failure of the wrapper.
    }

    func testStopBrowsingStopsEvents() async {
        let first = uniqueName("ptb-s1"), second = uniqueName("ptb-s2")
        let seen = Recorder()
        let registrar = makeBrowser(Recorder()), other = makeBrowser(Recorder()), browser = makeBrowser(seen)
        defer { registrar.deregister(); other.deregister(); browser.stopBrowsing() }
        browser.browse()
        registrar.register(instance: first, port: 45128)
        let found = await waitUntil(30) { seen.found.contains(first) }
        XCTAssertTrue(found, "browse never found \(first); events \(seen.events)")
        browser.stopBrowsing()
        let count = seen.events.count
        other.register(instance: second, port: 45129)
        registrar.deregister()
        try? await Task.sleep(for: .seconds(8))
        XCTAssertEqual(seen.events.count, count, "events after stopBrowsing: \(seen.events[count...])")
    }

    func testNonASCIIInstanceNameRoundTrips() async {
        let name = "ptb-민준" + uniqueName("")
        let seen = Recorder(), result = Recorder()
        let registrar = makeBrowser(Recorder()), browser = makeBrowser(seen), resolver = makeBrowser(result)
        defer { registrar.deregister(); browser.stopBrowsing() }
        browser.browse()
        registrar.register(instance: name, port: 45130)
        let found = await waitUntil(30) { seen.found.contains(name) }
        print("DNSSD-REPORT non-ASCII: registered \(name), browse labels \(seen.found)")
        XCTAssertTrue(found, "browse never reported \(name); labels \(seen.found)")
        resolver.resolve(instance: name) { result.addresses = $0 }
        let answered = await waitUntil(30) { result.addresses != nil }
        XCTAssertTrue(answered)
        XCTAssertTrue((result.addresses ?? []).allSatisfy { $0.port == 45130 } && !(result.addresses ?? []).isEmpty, "\(String(describing: result.addresses))")
    }
}
#endif
