import XCTest
@testable import PokeTokenBar

@MainActor
final class UsageReportLedgerTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Ledger = UsageReportLedger

    private func make(_ suite: String = "ledger") -> (Ledger, UserDefaults) {
        let defaults = TestDefaults.make(suite: suite)
        return (Ledger(defaults: defaults, timeZone: seoul), defaults)
    }

    private func day(_ date: Date) -> String {
        LocalUsageReader.localDayFormatter(timeZone: seoul).string(from: date)
    }

    func testTheSecretIsMadeOnceAndMatchesTheContract() async {
        let (ledger, defaults) = make()
        let secret = ledger.secret
        XCTAssertNotNil(secret.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression))
        XCTAssertEqual(secret.count, 43)
        XCTAssertEqual(ledger.secret, secret)
        XCTAssertEqual(Ledger(defaults: defaults, timeZone: seoul).secret, secret)
    }

    func testTheFirstDayIsSetOnce() async {
        let (ledger, _) = make()
        XCTAssertNil(ledger.firstDay)
        ledger.markReady(now: t0)
        XCTAssertEqual(ledger.firstDay, day(t0))
        ledger.markReady(now: t0.addingTimeInterval(5 * 86400))
        XCTAssertEqual(ledger.firstDay, day(t0))
    }

    func testTurningOffTwiceKeepsOnePeriodAndTurningOnClosesIt() async {
        let (ledger, _) = make()
        ledger.teamTurnedOn(now: t0) // nothing open: no change
        XCTAssertEqual(ledger.offPeriods, [])
        ledger.teamTurnedOff(now: t0)
        ledger.teamTurnedOff(now: t0.addingTimeInterval(60))
        XCTAssertEqual(ledger.offPeriods, [.init(start: t0, end: nil)])
        ledger.teamTurnedOn(now: t0.addingTimeInterval(120))
        XCTAssertEqual(ledger.offPeriods, [.init(start: t0, end: t0.addingTimeInterval(120))])
        ledger.teamTurnedOn(now: t0.addingTimeInterval(180)) // already closed: no change
        XCTAssertEqual(ledger.offPeriods.count, 1)
        ledger.teamTurnedOff(now: t0.addingTimeInterval(200)) // a new period after a closed one
        XCTAssertEqual(ledger.offPeriods.count, 2)
    }

    func testPresenceGoesToThePreviousTeamAndIsCapped() async {
        let (ledger, _) = make()
        let a = Ledger.TeamStamp(id: "A", label: "Alpha")
        let b = Ledger.TeamStamp(id: "B", label: "Beta")
        ledger.recordPresence(now: t0, team: a)
        ledger.recordPresence(now: t0.addingTimeInterval(600), team: b)
        ledger.recordPresence(now: t0.addingTimeInterval(700), team: b)
        func seconds(_ id: String) -> Double { ledger.dayTeams.filter { $0.team == id }.reduce(0) { $0 + $1.seconds } }
        XCTAssertEqual(seconds("A"), 600)
        XCTAssertEqual(seconds("B"), 100)
        ledger.recordPresence(now: t0.addingTimeInterval(700 + 36000), team: b)
        XCTAssertEqual(seconds("B"), 100 + 3900)
    }

    func testPresenceWithoutATeamAndZeroGapCountNothing() async {
        let (ledger, _) = make()
        ledger.recordPresence(now: t0, team: nil)
        ledger.recordPresence(now: t0.addingTimeInterval(600), team: .init(id: "A", label: "Alpha"))
        XCTAssertEqual(ledger.dayTeams, [])
        ledger.recordPresence(now: t0.addingTimeInterval(600), team: .init(id: "A", label: "Alpha"))
        XCTAssertEqual(ledger.dayTeams, [])
    }

    func testTheFirstPresenceAfterLaunchCountsNothing() async {
        let (ledger, defaults) = make()
        let a = Ledger.TeamStamp(id: "A", label: "Alpha")
        ledger.recordPresence(now: t0, team: a)
        ledger.recordPresence(now: t0.addingTimeInterval(60), team: a)
        XCTAssertEqual(ledger.dayTeams.first?.seconds, 60)
        let relaunched = Ledger(defaults: defaults, timeZone: seoul)
        relaunched.recordPresence(now: t0.addingTimeInterval(9000), team: a)
        XCTAssertEqual(relaunched.dayTeams.first?.seconds, 60)
    }

    func testTheDominantTeamIsTheLongestStay() async {
        let e = [
            Ledger.DayTeamEntry(day: "2026-01-01", team: "B", label: "Beta", seconds: 100),
            .init(day: "2026-01-01", team: "A", label: "Alpha", seconds: 300),
            .init(day: "2026-01-01", team: "C", label: "Gamma", seconds: 300),
            .init(day: "2026-01-02", team: "Z", label: "Zed", seconds: 5),
        ]
        XCTAssertEqual(Ledger.dominantTeam(on: "2026-01-01", in: e), .init(id: "A", label: "Alpha"))
        XCTAssertEqual(Ledger.dominantTeam(on: "2026-01-02", in: e), .init(id: "Z", label: "Zed"))
        XCTAssertNil(Ledger.dominantTeam(on: "2026-01-03", in: e))
    }

    func testCommitMergesAndPrunesOldEntries() async {
        let (ledger, _) = make()
        let old = t0.addingTimeInterval(-46 * 86400)
        let recent = t0.addingTimeInterval(-44 * 86400)
        let a = Ledger.TeamStamp(id: "A", label: "Alpha")
        for date in [old, recent] {
            ledger.recordPresence(now: date, team: a)
            ledger.recordPresence(now: date.addingTimeInterval(60), team: a)
        }
        ledger.teamTurnedOff(now: old)
        ledger.teamTurnedOn(now: old.addingTimeInterval(60))
        ledger.teamTurnedOff(now: recent)
        ledger.teamTurnedOn(now: recent.addingTimeInterval(60))
        ledger.teamTurnedOff(now: t0) // open period survives
        ledger.commit(days: [day(old): "x", day(recent): "y"], limits: ["a|claude": 1], at: t0)
        XCTAssertEqual(ledger.sentDays, [day(recent): "y"])
        XCTAssertEqual(ledger.dayTeams.map(\.day), [day(recent)])
        XCTAssertEqual(ledger.offPeriods.count, 2)
        XCTAssertEqual(ledger.lastSentAt, t0)
        ledger.commit(days: [day(recent): "z"], limits: ["b|codex": 2], at: t0.addingTimeInterval(10))
        XCTAssertEqual(ledger.sentDays, [day(recent): "z"])
        XCTAssertEqual(ledger.sentLimits, ["a|claude": 1, "b|codex": 2])
    }

    func testStateSurvivesANewLedgerOnTheSameDefaults() async {
        let (ledger, defaults) = make()
        ledger.markReady(now: t0)
        ledger.teamTurnedOff(now: t0)
        ledger.commit(days: [day(t0): "f"], limits: ["k": 3], at: t0)
        XCTAssertNil(Ledger(defaults: TestDefaults.make(suite: "other"), timeZone: seoul).lastSentAt)
        let again = Ledger(defaults: defaults, timeZone: seoul)
        XCTAssertEqual(again.firstDay, day(t0))
        XCTAssertEqual(again.offPeriods.count, 1)
        XCTAssertEqual(again.sentDays, [day(t0): "f"])
        XCTAssertEqual(again.sentLimits, ["k": 3])
        XCTAssertEqual(again.lastSentAt, t0)
    }
}
