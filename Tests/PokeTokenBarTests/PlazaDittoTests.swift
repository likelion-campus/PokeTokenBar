import XCTest
@testable import PokeTokenBar

final class PlazaDittoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(_ x: Int = 3, _ y: Int = 4, decoy: String? = nil, since: Date? = nil, rest: Date? = nil) -> PlazaDittoState {
        PlazaDittoState(tile: TilePoint(x: x, y: y), facing: .down, isWalking: nil, isRunning: nil,
                        decoyOf: decoy, since: since ?? now, restUntil: rest)
    }

    func testHostIsTheSmallestReadyID() {
        XCTAssertEqual(PlazaDitto.host(me: "b", meReady: true, others: ["a": true, "c": true]), "a")
        XCTAssertEqual(PlazaDitto.host(me: "b", meReady: true, others: ["a": false, "c": true]), "b")
        XCTAssertNil(PlazaDitto.host(me: "b", meReady: false, others: ["a": false]))
    }

    func testOnlyActiveHatchedTeammatesWithTheWindowOpenCanBeCopied() {
        func f(_ p: Bool = true, _ r: Bool = true, _ i: Bool = false, _ fo: Bool = false, _ e: Bool = false) -> Bool {
            PlazaDitto.canBeCopied(inPlaza: p, ready: r, isIdle: i, isFocusing: fo, isEgg: e)
        }
        XCTAssertTrue(f())
        XCTAssertFalse(f(false)); XCTAssertFalse(f(true, false)); XCTAssertFalse(f(true, true, true))
        XCTAssertFalse(f(true, true, false, true)); XCTAssertFalse(f(true, true, false, false, true))
    }

    func testCopyTargetIsANeighbourNotADiagonal() {
        let d = TilePoint(x: 10, y: 10)
        XCTAssertEqual(PlazaDitto.copyTarget(ditto: d, copyable: ["x": TilePoint(x: 11, y: 10)]), "x")
        XCTAssertNil(PlazaDitto.copyTarget(ditto: d, copyable: ["x": TilePoint(x: 11, y: 11)]))
        XCTAssertEqual(PlazaDitto.copyTarget(ditto: d, copyable: ["b": TilePoint(x: 10, y: 9), "a": TilePoint(x: 9, y: 10)]), "a")
    }

    func testGroundExcludesWaterShelterAndTrees() {
        let map = PlazaMapData.map
        XCTAssertFalse(PlazaDitto.isGround(TilePoint(x: 5, y: 13), in: map), "water")
        XCTAssertFalse(PlazaDitto.isGround(TilePoint(x: 21, y: 6), in: map), "shelter")
        XCTAssertFalse(PlazaDitto.isGround(TilePoint(x: 0, y: 0), in: map), "tree")
        XCTAssertTrue(PlazaDitto.isGround(TilePoint(x: 3, y: 3), in: map), "grass")
    }

    func testCopyingAndTurningBack() {
        let later = now.addingTimeInterval(50)
        let c = state(rest: now).copying("m", now: later)
        XCTAssertEqual(c.tile, state().tile)
        XCTAssertEqual(c.decoyOf, "m"); XCTAssertEqual(c.since, later); XCTAssertNil(c.restUntil)
        var w = c; w.isWalking = true
        let t = w.turnedBack(now: later)
        XCTAssertNil(t.decoyOf); XCTAssertEqual(t.restUntil, later.addingTimeInterval(180))
        XCTAssertNotEqual(t.isWalking, true)
    }

    func testAcceptedDropsHostileStates() {
        XCTAssertNil(PlazaDittoState.accepted(state(decoy: String(repeating: "a", count: 65)), now: now))
        XCTAssertNotNil(PlazaDittoState.accepted(state(decoy: String(repeating: "a", count: 64)), now: now))
        XCTAssertNil(PlazaDittoState.accepted(state(since: now.addingTimeInterval(601)), now: now))
        XCTAssertNil(PlazaDittoState.accepted(state(decoy: "m", since: now.addingTimeInterval(-1501)), now: now))
        XCTAssertNotNil(PlazaDittoState.accepted(state(decoy: "m", since: now.addingTimeInterval(-1500)), now: now))
        XCTAssertNil(PlazaDittoState.accepted(state(rest: now.addingTimeInterval(781)), now: now))
        XCTAssertNotNil(PlazaDittoState.accepted(state(since: now.addingTimeInterval(-86_400)), now: now))
        XCTAssertNil(PlazaDittoState.accepted(nil, now: now))
    }

    func testChangeReportsTransformsAndTurnBacks() {
        XCTAssertEqual(PlazaDitto.change(from: state(), to: state(decoy: "a")), .transformed(TilePoint(x: 3, y: 4)))
        XCTAssertEqual(PlazaDitto.change(from: state(decoy: "a"), to: state()), .turnedBack(TilePoint(x: 3, y: 4)))
        XCTAssertEqual(PlazaDitto.change(from: state(decoy: "a"), to: state(decoy: "b")), .transformed(TilePoint(x: 3, y: 4)))
        XCTAssertEqual(PlazaDitto.change(from: state(), to: state(5, 5)), .none)
        XCTAssertEqual(PlazaDitto.change(from: nil, to: state(decoy: "a")), .none)
        XCTAssertEqual(PlazaDitto.change(from: nil, to: nil), .none)
    }

    func testStateRoundTripsAndOmitsFalseFlags() throws {
        let s = state()
        let enc = JSONEncoder()
        let data = try enc.encode(s)
        let json = String(decoding: data, as: UTF8.self)
        for k in ["isWalking", "decoyOf", "restUntil"] { XCTAssertFalse(json.contains(k), k) }
        XCTAssertEqual(try JSONDecoder().decode(PlazaDittoState.self, from: data), s)
    }
}
