import XCTest
@testable import PokeTokenBar

/// The `poketokenbar:` link's rules on Windows (stage 7 Task 23, part b): which start carries a link, the one parse it goes
/// through (the Mac's `AgentActivityEvent(url:)` behind a length cap) and the `WM_COPYDATA` payload. Shared: the Windows run
/// parses with Windows' Foundation, so both systems give the same verdicts.
final class AgentLinkRulesTests: XCTestCase {
    private let exe = #"C:\Users\me\AppData\Local\Programs\PokeTokenBar\PokeTokenBar.exe"#

    func testOnlyTheFirstArgumentCarriesALink() {
        XCTAssertNil(AgentLinkRules.link(in: [exe]))
        XCTAssertNil(AgentLinkRules.link(in: [exe, "--autostart"]))
        XCTAssertNil(AgentLinkRules.link(in: [exe, "--selftest", "poketokenbar://agent?state=done"]))
        XCTAssertEqual(AgentLinkRules.link(in: [exe, "poketokenbar://agent?state=done"]), "poketokenbar://agent?state=done")
        XCTAssertEqual(AgentLinkRules.link(in: [exe, "PokeTokenBar:agent"]), "PokeTokenBar:agent")
        XCTAssertNil(AgentLinkRules.link(in: [exe, "poketokenbars://agent?state=done"]))
        XCTAssertNil(AgentLinkRules.link(in: [exe, " poketokenbar://agent?state=done"]))
        // A link that closes the shell's quotes and adds arguments: the link is the first argument, the rest is never read.
        let injected = [exe, #"poketokenbar://agent?state=done&label=x""#, "--set-team-code", "ABCD", "--selftest"]
        XCTAssertEqual(AgentLinkRules.link(in: injected), #"poketokenbar://agent?state=done&label=x""#)
    }

    func testTheParseIsTheMacsBehindTheCap() throws {
        let cases: [(String, AgentActivity?, String?)] = [
            ("poketokenbar://agent?state=working", .working, nil),
            ("POKETOKENBAR://AGENT?state=DONE&message=ok", .done(message: "ok"), nil),
            ("poketokenbar://agent?state=waiting&label=api&message=Needs%20you", .waiting(message: "Needs you"), "api"),
            ("poketokenbar://agent?state=idle&label=a", .idle, "a"),
            ("poketokenbar://agent/any/path?state=done", .done(message: nil), nil),
            ("poketokenbar://agent?state=reboot", nil, nil),
            ("poketokenbar://other?state=done", nil, nil),
            ("poketokenbar:agent?state=done", nil, nil),
            ("poketokenbar://agent", nil, nil),
            ("poketokenbar://agent?label=x", nil, nil),
            ("https://agent?state=done", nil, nil),
            (#"C:\Windows\System32\cmd.exe"#, nil, nil),
            ("file:///C:/Windows/System32/cmd.exe", nil, nil),
        ]
        for (link, activity, label) in cases {
            let event = AgentLinkRules.event(fromLink: link)
            XCTAssertEqual(event?.activity, activity, link)
            XCTAssertEqual(event?.label, label, link)
            XCTAssertEqual(event, URL(string: link).flatMap(AgentActivityEvent.init(url:)), "the Mac's verdict: \(link)")
        }
        // The cap: a link of exactly `maxLength` units is read, one more is not.
        let head = "poketokenbar://agent?state=done&message="
        let fits = head + String(repeating: "a", count: AgentLinkRules.maxLength - head.utf16.count)
        XCTAssertEqual(fits.utf16.count, AgentLinkRules.maxLength)
        XCTAssertEqual(AgentLinkRules.event(fromLink: fits)?.activity, .done(message: String(repeating: "a", count: AgentActivityEvent.maxMessageLength - 1) + "…"))
        XCTAssertNil(AgentLinkRules.event(fromLink: fits + "a"))
        // The longest message and label the pet shows, percent-encoded at the most bytes a scalar takes, fit under the cap.
        let worst = String(repeating: "%F0%9F%98%80", count: AgentActivityEvent.maxMessageScalars)
        let label = String(repeating: "%F0%9F%98%80", count: AgentActivityEvent.maxLabelLength * 4)
        let longest = "poketokenbar://agent?state=waiting&label=\(label)&message=\(worst)"
        XCTAssertLessThan(longest.utf16.count, AgentLinkRules.maxLength)
        XCTAssertNotNil(AgentLinkRules.event(fromLink: longest))
    }

    func testTheCopyDataPayloadTakesOnlyAWholeTaggedLink() throws {
        func bytes(_ units: [UInt16]) -> [UInt8] { units.withUnsafeBytes { Array($0) } }
        func read(_ tag: UInt, _ b: [UInt8]) -> String? { b.withUnsafeBytes { AgentLinkRules.link(tag: tag, bytes: $0) } }
        for link in ["poketokenbar://agent?state=done", "poketokenbar://agent?state=waiting&label=한글&message=日本語 🦊", "x"] {
            let units = try XCTUnwrap(AgentLinkRules.payload(link))
            XCTAssertEqual(read(AgentLinkRules.copyDataTag, bytes(units)), link)
            XCTAssertNil(read(AgentLinkRules.copyDataTag + 1, bytes(units)), "another tag")
            XCTAssertNil(read(0, bytes(units)), "no tag")
            XCTAssertNil(read(AgentLinkRules.copyDataTag, Array(bytes(units).dropLast())), "half a unit")
        }
        XCTAssertNil(AgentLinkRules.payload(""))
        XCTAssertNil(read(AgentLinkRules.copyDataTag, []))
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes([0x70, 0x00, 0x6B])), "a NUL inside")
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes([0x70, 0xD800, 0x6B])), "a lone surrogate")
        let longest = [UInt16](repeating: 0x61, count: AgentLinkRules.maxLength)
        XCTAssertNotNil(read(AgentLinkRules.copyDataTag, bytes(longest)))
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes(longest + [0x61])), "over the cap")
        XCTAssertNil(AgentLinkRules.payload(String(repeating: "a", count: AgentLinkRules.maxLength + 1)))
        XCTAssertEqual(AgentLinkRules.copyDataTag, 0x5054_4241)   // "PTBA": a fixed value the sender and the receiver share
    }
}
