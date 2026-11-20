import XCTest
@testable import PokeTokenBar

/// Two real sessions over real loopback sockets; the scenario is in the transport contract.
@MainActor
final class TeamSessionLoopbackTests: XCTestCase {
    private let harness = MacTransportHarness()

    override func tearDown() async throws { harness.tearDown() }

    func testLaterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems() async throws {
        try await TeamTransportContract.laterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems(harness)
    }
}
