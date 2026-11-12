import XCTest
import AppKit
@testable import PokeTokenBar

/// A fetcher that never delivers, so every frame set is a placeholder and the retry chain keeps asking.
private struct NeverDeliversFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// The sprite retry chain used to hold the controller strongly while it waited to ask again, so a controller whose
/// sprites never arrive outlived whoever made it and kept ticking (the Ditto loop at 20 Hz) into closures that were gone.
@MainActor
final class PlazaControllerLifetimeTests: XCTestCase {
    func testAControllerWhoseSpritesNeverArriveDiesWhenItsOwnerLetsGo() async throws {
        weak var controller: PlazaWindowController?
        weak var scene: PlazaScene?
        do {
            let hub = FakeTransportHub()
            var rng = SystemRandomNumberGenerator()
            let code = TeamCode.generate(using: &rng)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaControllerLifetimeTests-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
            func node(_ name: String) -> (TeamSession, FakeTeamTransport, TeamSettings) {
                let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.lifetime.\(UUID())"))
                settings.code = code
                settings.nickname = name
                settings.isEnabled = true
                let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("\(name).json"), myMemberID: settings.memberID)
                let transport = hub.makeTransport()
                let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                          profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
                session.updateCharacter(mon)
                session.applySettings()
                return (session, transport, settings)
            }
            let (me, meT, meS) = node("나")
            let (other, otherT, _) = node("가")
            defer { withExtendedLifetime(other) {} }
            let c = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.lifetime.prefs.\(UUID())")),
                                          loader: PlazaCharacterLoader(fetcher: NeverDeliversFetcher()),
                                          nickname: { "나" }, memberID: { meS.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) },
                                          myRosterEntry: { nil }, session: me, clock: { Date() })
            c.prepareScene()
            _ = hub.connect(meT, to: otherT)
            let s = try XCTUnwrap(c.scene)
            for _ in 0..<400 where me.members.isEmpty { await Task.yield() }
            for _ in 0..<50 { await Task.yield() }
            XCTAssertFalse(me.members.isEmpty, "a teammate with a placeholder sprite is what starts the retry chain")
            controller = c
            scene = s
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(controller, "a retry waiting to ask again must not keep the controller alive")
        XCTAssertNil(scene)
    }
}
