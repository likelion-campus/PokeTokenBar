import XCTest
@testable import PokeTokenBar

/// The `poketokenbar:` link's rules on Windows (stage 7 Task 23, part b): what a start of the app does with its command line,
/// the one parse a link goes through (the Mac's `AgentActivityEvent(url:)` behind a length cap) and the `WM_COPYDATA` payload.
/// Shared: the Windows run parses with Windows' Foundation, so both systems must give the verdicts written here.
final class AgentLinkRulesTests: XCTestCase {
    private let exe = #"C:\Users\me\AppData\Local\Programs\PokeTokenBar\PokeTokenBar.exe"#
    private let link = "poketokenbar://agent?state=done"

    private func decide(_ arguments: [String], running: Bool = false, elevated: Bool = false) -> AgentLinkRules.StartDecision {
        AgentLinkRules.decide(arguments, appRunning: { running }, elevated: { elevated })
    }

    /// The start decision (review I1, I2, M1, M2). Kills: a dropped `count == 3` (the smuggled flags would start), a dropped
    /// flag test (a bare link would be read as the app's flags), a dropped `isLink` (any text after the flag would start the
    /// app), a dropped elevation test (an elevated opener would start an elevated app).
    func testAStartIsALinkStartOnlyByTheFlagAndThenOnlyInItsExactShape() async {
        // Not a link start: the app's own arguments, untouched.
        XCTAssertEqual(decide([exe]), .app([exe]))
        XCTAssertEqual(decide([exe, "--autostart"]), .app([exe, "--autostart"]))
        XCTAssertEqual(decide([exe, "--selftest", "poketokenbar://agent?state=done"]), .app([exe, "--selftest", "poketokenbar://agent?state=done"]))
        // The shell's exact shape: forwarded to a running app; a clean start when none runs; nothing when elevated with none.
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, link], running: true), .forward(link))
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, "PokeTokenBar://Agent?state=done"], running: true), .forward("PokeTokenBar://Agent?state=done"))
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, link]), .startClean)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, link], elevated: true), .drop)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, link], running: true, elevated: true), .forward(link), "an elevated opener may still hand a link over")
        // A link that closed its quotes and added flags: the whole start is dropped, with or without an app running.
        let smuggled = [exe, AgentLinkRules.flag, #"poketokenbar://agent?state=done""#, "--selftest-x", ""]
        XCTAssertEqual(decide(smuggled), .drop)
        XCTAssertEqual(decide(smuggled, running: true), .drop)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, link, "--set-team-code", "ABCD"], running: true), .drop)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag]), .drop)
        // After the flag only a poketokenbar: link counts.
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, "--selftest"]), .drop)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, "https://example.com"], running: true), .drop)
        XCTAssertEqual(decide([exe, AgentLinkRules.flag, " poketokenbar://agent?state=done"]), .drop)
        // A bare link first (another program's registration, the old form): dropped, never the app's flags.
        XCTAssertEqual(decide([exe, link]), .drop)
        XCTAssertEqual(decide([exe, link, "--selftest-second"], running: true), .drop)
        XCTAssertEqual(decide([exe, "POKETOKENBAR:x"]), .drop)
        // What a clean start runs: the quiet start, nothing of the link's command line.
        XCTAssertEqual(AgentLinkRules.cleanStartArguments, ["--autostart"])
    }

    /// The running app is looked for only for a well-formed link start, and elevation only when none runs.
    func testTheSystemIsAskedOnlyWhenTheShapeIsRight() async {
        var asked: [String] = []
        _ = AgentLinkRules.decide([exe, AgentLinkRules.flag, link, "x"], appRunning: { asked.append("running"); return false }, elevated: { asked.append("elevated"); return false })
        _ = AgentLinkRules.decide([exe, "--autostart"], appRunning: { asked.append("running"); return false }, elevated: { asked.append("elevated"); return false })
        XCTAssertEqual(asked, [])
        _ = AgentLinkRules.decide([exe, AgentLinkRules.flag, link], appRunning: { asked.append("running"); return true }, elevated: { asked.append("elevated"); return false })
        XCTAssertEqual(asked, ["running"])
    }

    /// The parse, with the verdict written out (review M7: these are what both systems must give; the Windows run checks
    /// Windows' Foundation against them).
    func testTheParseGivesTheseVerdicts() async throws {
        let cases: [(String, AgentActivity?, String?)] = [
            ("poketokenbar://agent?state=working", .working, nil),
            ("POKETOKENBAR://AGENT?state=DONE&message=ok", .done(message: "ok"), nil),
            ("poketokenbar://agent?state=waiting&label=api&message=Needs%20you", .waiting(message: "Needs you"), "api"),
            ("poketokenbar://agent?state=idle&label=a", .idle, "a"),
            ("poketokenbar://agent/any/path?state=done", .done(message: nil), nil),
            ("poketokenbar://agent?state=done&label=%22quoted%22", .done(message: nil), "\"quoted\""),
            ("poketokenbar://agent?state=done&message=a+b", .done(message: "a+b"), nil),
            ("poketokenbar://agent?state=done#fragment", .done(message: nil), nil),
            ("poketokenbar://agent?state=done&state=working", .done(message: nil), nil),
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
        }
        // Inputs Foundation reads leniently (macOS 14 and swift-foundation encode an unencoded space or quote, keep a bad
        // escape as text, drop a value that is not UTF-8, decode an encoded host): the verdicts both systems give.
        let lenient: [(String, AgentActivity, String?)] = [
            ("poketokenbar://agent?state=done&message=hi there", .done(message: "hi there"), nil),
            (#"poketokenbar://agent?state=done&label=x""#, .done(message: nil), #"x""#),
            ("poketokenbar://agent?state=done&message=%ZZ", .done(message: "%ZZ"), nil),
            ("poketokenbar://agent?state=done&message=%FF%FE", .done(message: nil), nil),
            ("poketokenbar://%61gent?state=done", .done(message: nil), nil),
        ]
        for (link, activity, label) in lenient {
            let event = AgentLinkRules.event(fromLink: link)
            print("LINK-VERDICT \(link) -> \(event.map { "\($0.activity) label=\($0.label ?? "nil")" } ?? "refused")")
            XCTAssertEqual(event?.activity, activity, link)
            XCTAssertEqual(event?.label, label, link)
        }
        // The cap: a link of exactly `maxLength` units is read, one more is not.
        let head = "poketokenbar://agent?state=done&message="
        let fits = head + String(repeating: "a", count: AgentLinkRules.maxLength - head.utf16.count)
        XCTAssertEqual(fits.utf16.count, AgentLinkRules.maxLength)
        XCTAssertEqual(AgentLinkRules.event(fromLink: fits)?.activity, .done(message: String(repeating: "a", count: AgentActivityEvent.maxMessageLength - 1) + "…"))
        XCTAssertNil(AgentLinkRules.event(fromLink: fits + "a"))
        // The longest message and label the pet shows, percent-encoded at the most a scalar takes (12 characters), fit under
        // the cap: 5,042 units (review M4: the number the comments give).
        let worst = String(repeating: "%F0%9F%98%80", count: AgentActivityEvent.maxMessageScalars)
        let label = String(repeating: "%F0%9F%98%80", count: AgentActivityEvent.maxLabelLength * 4)
        let longest = "poketokenbar://agent?state=waiting&label=\(label)&message=\(worst)"
        XCTAssertEqual(longest.utf16.count, 5_042)
        XCTAssertLessThan(longest.utf16.count, AgentLinkRules.maxLength)
        XCTAssertNotNil(AgentLinkRules.event(fromLink: longest))
    }

    func testTheCopyDataPayloadTakesOnlyAWholeTaggedLink() async throws {
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
        // A lone surrogate from a local program (review M6): refused by the decode, no trap.
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes([0x70, 0xD800, 0x6B])), "a lone high surrogate")
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes([0xDC00])), "a lone low surrogate")
        let longest = [UInt16](repeating: 0x61, count: AgentLinkRules.maxLength)
        XCTAssertNotNil(read(AgentLinkRules.copyDataTag, bytes(longest)))
        XCTAssertNil(read(AgentLinkRules.copyDataTag, bytes(longest + [0x61])), "over the cap")
        XCTAssertNil(AgentLinkRules.payload(String(repeating: "a", count: AgentLinkRules.maxLength + 1)))
        XCTAssertEqual(AgentLinkRules.copyDataTag, 0x5054_4241)   // "PTBA": a fixed value the sender and the receiver share
    }
}
