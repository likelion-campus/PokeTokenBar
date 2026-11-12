import XCTest
@testable import PokeTokenBar

final class PlazaMimicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func honest(species: Int? = 132, inPlaza: Bool = true, mimicOf: String? = "x", seen: Bool = true) -> TeamMemberState {
        var m = TeamMemberState(
            memberID: "m", nickname: "m",
            character: TeamMonSummary(speciesID: species, isShiny: false, form: nil, speciesName: nil, gender: nil),
            inPlaza: inPlaza, tile: nil, facing: nil, isWalking: false)
        m.mimicOf = mimicOf
        m.mimicSeenAt = seen ? t0 : nil
        return m
    }

    private let plaza: Set<String> = ["m", "x", "me"]

    func testOnlyDittoIsDitto() {
        XCTAssertTrue(PlazaMimic.isDitto(speciesID: 132))
        XCTAssertFalse(PlazaMimic.isDitto(speciesID: 25))
        XCTAssertFalse(PlazaMimic.isDitto(speciesID: nil))
    }

    func testTackleDisguisesSwitchesReleasesOrKeeps() {
        XCTAssertEqual(PlazaMimic.tackle("x", mine: nil, targetIsDisguised: false, targetInPlaza: true), .disguise(as: "x"))
        XCTAssertEqual(PlazaMimic.tackle("y", mine: "x", targetIsDisguised: false, targetInPlaza: true), .disguise(as: "y"))
        XCTAssertEqual(PlazaMimic.tackle("x", mine: "x", targetIsDisguised: false, targetInPlaza: true), .release)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: nil, targetIsDisguised: true, targetInPlaza: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: "x", targetIsDisguised: true, targetInPlaza: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: "b", targetIsDisguised: true, targetInPlaza: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("x", mine: nil, targetIsDisguised: false, targetInPlaza: false), .keep)
    }

    func testMyDisguiseIsOverAfterFiveMinutesALeaveOrALostDitto() {
        XCTAssertFalse(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(299.9), targetInPlaza: true, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(300), targetInPlaza: true, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(1), targetInPlaza: false, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(1), targetInPlaza: true, amDitto: false))
    }

    func testShownTargetFollowsAnHonestDisguise() {
        let m = honest()
        XCTAssertEqual(PlazaMimic.shownTarget(of: m, now: t0.addingTimeInterval(304.9), inPlaza: plaza), "x")
        XCTAssertNil(PlazaMimic.shownTarget(of: m, now: t0.addingTimeInterval(305), inPlaza: plaza))
        XCTAssertEqual(PlazaMimic.shownTarget(of: honest(mimicOf: "me"), now: t0, inPlaza: plaza), "me")
    }

    func testShownTargetDropsHostileValues() {
        let now = t0.addingTimeInterval(1)
        let cases: [(String, TeamMemberState)] = [
            ("not a Ditto", honest(species: 25)),
            ("egg", honest(species: nil)),
            ("itself", honest(mimicOf: "m")),
            ("gone", honest(mimicOf: "gone")),
            ("plaza-ditto", honest(mimicOf: "plaza-ditto")),
            ("not in plaza", honest(inPlaza: false)),
            ("never seen", honest(seen: false)),
            ("no target", honest(mimicOf: nil)),
        ]
        for (label, m) in cases {
            XCTAssertNil(PlazaMimic.shownTarget(of: m, now: now, inPlaza: plaza), label)
        }
    }
}
