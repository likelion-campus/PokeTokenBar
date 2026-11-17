import XCTest
@testable import PokeTokenBar

/// The hatch base index built over REST when GraphQL fails (`PokeAPIClient.runRESTBuild`). Before: 649 fetches every session
/// until one session got through all of them, nothing kept in between (run 44143290510: a slow PokeAPI kept it going through
/// three idle-gate launches). Now a session stops at the first round with a network error or with no species answer at all,
/// keeps what it has, and the next session goes on from there.
final class BaseIndexRESTBuildTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int] = []
        private var saved: [RESTIndexProgress] = []
        func fetched(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
        func save(_ p: RESTIndexProgress) { lock.lock(); saved.append(p); lock.unlock() }
        var fetchedIDs: [Int] { lock.lock(); defer { lock.unlock() }; return ids.sorted() }
        var saves: [RESTIndexProgress] { lock.lock(); defer { lock.unlock() }; return saved }
    }

    private struct NotASpecies: Error {}

    private let fresh = RESTIndexProgress(fetchedAt: Date(timeIntervalSince1970: 0), nextID: 1, bases: [])

    /// Even ids are bases, odd ones are not (`nil`), as `baseSpecies(id:)` answers.
    private static func answer(_ id: Int) -> BaseSpecies? { id % 2 == 0 ? BaseSpecies(id: id, captureRate: 45) : nil }

    private func run(from start: RESTIndexProgress, _ log: Log,
                     _ fetch: @escaping @Sendable (Int) async throws -> BaseSpecies?) async -> (RESTIndexProgress, RESTIndexStop) {
        await PokeAPIClient.runRESTBuild(from: start, maxID: 649, batchSize: 6, fetch: { id in
            log.fetched(id)
            return try await fetch(id)
        }, save: { log.save($0) })
    }

    func testOfflineStopsAfterOneRoundAndKeepsNothing() async {
        let log = Log()
        let (progress, stop) = await run(from: fresh, log) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(stop, .network)
        XCTAssertEqual(log.fetchedIDs, Array(1...6), "one round, not 649 fetches")
        XCTAssertEqual(progress.nextID, 1)
        XCTAssertTrue(log.saves.isEmpty)
    }

    func testAServerThatAnswersNoSpeciesStopsAfterOneRound() async {
        let log = Log()
        let (progress, stop) = await run(from: fresh, log) { _ in throw NotASpecies() }  // a 5xx page does not decode
        XCTAssertEqual(stop, .unanswered)
        XCTAssertEqual(log.fetchedIDs, Array(1...6))
        XCTAssertEqual(progress.nextID, 1)
    }

    func testTheNextSessionGoesOnWhereANetworkErrorStoppedThisOne() async throws {
        let first = Log()
        let (kept, stop) = await run(from: fresh, first) { id in
            if id == 100 { throw URLError(.timedOut) }
            return Self.answer(id)
        }
        XCTAssertEqual(stop, .network)
        XCTAssertEqual(kept.nextID, 97, "the round 97...102 held the failure; it is not skipped")
        XCTAssertEqual(kept.bases.map(\.id).sorted(), Array(stride(from: 2, through: 96, by: 2)))
        XCTAssertEqual(try XCTUnwrap(first.saves.last), kept, "what was kept is on disk")
        XCTAssertEqual(first.fetchedIDs.max(), 102)

        let second = Log()
        let (done, end) = await run(from: kept, second) { Self.answer($0) }
        XCTAssertEqual(end, .finished)
        XCTAssertEqual(second.fetchedIDs, Array(97...649), "nothing fetched twice across the two sessions but the failed round")
        XCTAssertEqual(done.bases.map(\.id).sorted(), Array(stride(from: 2, through: 648, by: 2)))
    }

    func testOneUnansweredSpeciesIsSkippedAndTheBuildFinishes() async {
        let log = Log()
        let (done, stop) = await run(from: fresh, log) { id in
            if id == 50 { throw NotASpecies() }
            return Self.answer(id)
        }
        XCTAssertEqual(stop, .finished)
        XCTAssertEqual(log.fetchedIDs, Array(1...649))
        XCTAssertFalse(done.bases.contains { $0.id == 50 })
        XCTAssertEqual(done.bases.count, 324 - 1)
    }
}
