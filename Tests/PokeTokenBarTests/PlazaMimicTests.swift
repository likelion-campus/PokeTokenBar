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
        XCTAssertEqual(PlazaMimic.tackle("x", mine: nil, targetIsDisguised: false, targetCopyable: true), .disguise(as: "x"))
        XCTAssertEqual(PlazaMimic.tackle("y", mine: "x", targetIsDisguised: false, targetCopyable: true), .disguise(as: "y"))
        XCTAssertEqual(PlazaMimic.tackle("x", mine: "x", targetIsDisguised: false, targetCopyable: true), .release)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: nil, targetIsDisguised: true, targetCopyable: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: "x", targetIsDisguised: true, targetCopyable: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("b", mine: "b", targetIsDisguised: true, targetCopyable: true), .keep)
        XCTAssertEqual(PlazaMimic.tackle("x", mine: nil, targetIsDisguised: false, targetCopyable: false), .keep)
    }

    func testMyDisguiseIsOverAfterFiveMinutesALeaveOrALostDitto() {
        XCTAssertFalse(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(299.9), targetInPlaza: true, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(300), targetInPlaza: true, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(1), targetInPlaza: false, amDitto: true))
        XCTAssertTrue(PlazaMimic.isOver(since: t0, now: t0.addingTimeInterval(1), targetInPlaza: true, amDitto: false))
    }

    func testLettingGoNeedsNoCopyableTarget() {
        XCTAssertEqual(PlazaMimic.tackle("x", mine: "x", targetIsDisguised: false, targetCopyable: false), .release,
                       "letting go of the one I already am is always allowed")
    }

    func testAClockThatJumpedBackEndsMyDisguise() {
        XCTAssertTrue(PlazaMimic.isOver(since: t0.addingTimeInterval(3600), now: t0, targetInPlaza: true, amDitto: true))
        XCTAssertFalse(PlazaMimic.isOver(since: t0.addingTimeInterval(PlazaMimic.receiverGrace), now: t0, targetInPlaza: true, amDitto: true),
                       "a small step back is still tolerated")
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

    func testTheHintNamesThemAndCountsDown() {
        XCTAssertEqual(L(.ko).plazaMimicHint(nickname: "지아", seconds: 252), "지아로 변신 중 · 4:12")
        XCTAssertEqual(L(.ko).plazaMimicHint(nickname: "도윤", seconds: 0.2), "도윤으로 변신 중 · 0:01")
        XCTAssertEqual(L(.ko).plazaMimicHint(nickname: "지아", seconds: 300), "지아로 변신 중 · 5:00")
        XCTAssertEqual(L(.ko).plazaMimicHint(nickname: "지아", seconds: -3), "지아로 변신 중 · 0:00")
    }
}
