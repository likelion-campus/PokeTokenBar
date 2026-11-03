import XCTest
import AppKit
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private struct OfflineLineProvider: PokeProviding {
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw CancellationError() }
}

/// Plaza items: a rare candy or a mint now and then, the same everywhere, picked up by whoever steps on it.
@MainActor
final class PlazaItemsTests: XCTestCase {
    private let map = PlazaMapData.map
    private var candidates: [TilePoint] { PlazaItems.candidates(in: map) }
    /// A slot whose item is up, and a moment while it is.
    private let slot = 160_000
    private var spawn: PlazaItems.Spawn { PlazaItems.spawn(slot: slot, candidates: candidates)! }
    private var during: Date { spawn.appearsAt.addingTimeInterval(60) }

    // MARK: - Rules

    func testCandidatesAreOpenGroundOnly() {
        let shelter = Set(map.shelterTiles)
        XCTAssertFalse(candidates.isEmpty)
        for t in candidates {
            XCTAssertTrue(map.isWalkable(t))
            XCTAssertFalse(shelter.contains(t), "\(t) is in the shelter")
            XCTAssertFalse([PlazaDirection.up, .down, .left, .right].contains { map.tile(at: PlazaWalker.offset(t, $0)) == .board },
                           "\(t) is next to the sign")
        }
    }

    /// Every slot of three hours drops one item, at a minute within its first two hours, on an open tile, and it
    /// stays until the slot ends. The same slot gives the same item on every Mac.
    func testEachSlotDropsOneItemTheSameEverywhere() {
        var kinds: [ItemKind: Int] = [:]
        for s in slot..<(slot + 1000) {
            let a = PlazaItems.spawn(slot: s, candidates: candidates)!, b = PlazaItems.spawn(slot: s, candidates: candidates)!
            XCTAssertEqual(a, b)
            let start = Date(timeIntervalSince1970: Double(s) * PlazaItems.slotLength)
            XCTAssertGreaterThanOrEqual(a.appearsAt, start)
            XCTAssertLessThan(a.appearsAt, start.addingTimeInterval(PlazaItems.appearWindow))
            XCTAssertEqual(a.appearsAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0, "on the minute")
            XCTAssertEqual(a.endsAt, start.addingTimeInterval(PlazaItems.slotLength))
            XCTAssertTrue(candidates.contains(a.tile))
            kinds[a.kind, default: 0] += 1
        }
        XCTAssertEqual(Set(kinds.keys), [.rareCandy, .mint])
        XCTAssertEqual(Double(kinds[.rareCandy] ?? 0) / 1000, PlazaItems.candyShare, accuracy: 0.06)
        XCTAssertEqual(PlazaItems.slotLength, 3 * 3600, "one item every three hours: people have work to do")
    }

    func testTheItemIsUpFromItsMinuteUntilTheSlotEndsUnlessPicked() {
        let s = spawn
        XCTAssertNil(PlazaItems.current(at: s.appearsAt.addingTimeInterval(-1), candidates: candidates, picked: []))
        XCTAssertEqual(PlazaItems.current(at: s.appearsAt, candidates: candidates, picked: []), s)
        XCTAssertEqual(PlazaItems.current(at: s.endsAt.addingTimeInterval(-1), candidates: candidates, picked: []), s)
        XCTAssertNotEqual(PlazaItems.current(at: s.endsAt, candidates: candidates, picked: [])?.slot, s.slot, "gone when the slot ends")
        XCTAssertNil(PlazaItems.current(at: during, candidates: candidates, picked: [s.slot]))
    }

    // MARK: - Scene

    private func scene(on tile: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: tile, zoom: 2, nickname: "나")
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        let now = during
        s.now = { now }
        return s
    }

    private func beside(_ t: TilePoint) -> (TilePoint, UInt16)? {
        let options: [(PlazaDirection, UInt16)] = [(.left, 124), (.right, 123), (.up, 125), (.down, 126)]
        for (side, key) in options {
            let from = PlazaWalker.offset(t, side)
            if map.isWalkable(from) { return (from, key) }
        }
        return nil
    }

    /// The item lies on its tile; walking onto it reports the pickup, and once picked it is gone.
    func testWalkingOntoTheItemPicksItUp() throws {
        let (from, key) = try XCTUnwrap(beside(spawn.tile))
        let s = scene(on: from)
        var picked: [PlazaItems.Spawn] = []
        s.onItemPickup = { picked.append($0) }
        s.update(0)
        XCTAssertEqual(s.itemTile, spawn.tile)
        XCTAssertTrue(picked.isEmpty)
        s.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        s.handleKeyUp(keyCode: key)
        var t = 0.0
        while picked.isEmpty && t < 1 { t += 1.0 / 60; s.update(t) }
        XCTAssertEqual(picked.first, spawn)
        s.pickedItemSlots = [spawn.slot]
        s.update(t + 0.1)
        XCTAssertNil(s.itemTile, "picked, so gone")
    }

    func testNoItemBeforeItsMinuteOrWithTheBackgroundHidden() {
        let s = scene(on: map.spawn)
        let before = spawn.appearsAt.addingTimeInterval(-60)
        s.now = { before }
        s.update(0)
        XCTAssertNil(s.itemTile)
        let now = during
        s.now = { now }
        s.update(0.1)
        XCTAssertEqual(s.itemTile, spawn.tile)
        s.setBackgroundHidden(true)
        s.update(0.2)
        XCTAssertNil(s.itemTile, "no ground, no item")
    }

    /// The photo shows the item where it lies.
    func testThePhotoShowsTheItem() throws {
        let (from, _) = try XCTUnwrap(beside(spawn.tile))
        let s = scene(on: from)   // the camera follows me, so stand next to it
        s.update(0)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.items.count, 1)
        let withItem = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        var bare = input
        bare.items = []
        let without = try XCTUnwrap(PlazaPhotoRenderer.render(bare))
        XCTAssertNotEqual(withItem.dataProvider?.data as Data?, without.dataProvider?.data as Data?)
    }

    // MARK: - Team

    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var granted: [ItemKind] = []

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        granted = []
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
    }

    private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
    }

    private func node(_ name: String) -> Node {
        let suite = "plaza.items.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaItemsTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
        session.updateCharacter(mon)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func prefsSuite() -> String {
        let name = "plaza.items.prefs.\(UUID())"
        suites.append(name)
        return name
    }

    private func controller(_ me: Node, prefs suite: String, start: TilePoint) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: suite)!)
        prefs.saveLastTile(start)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      grantItem: { [weak self] in self?.granted.append($0) },
                                      session: me.session, bannerSleep: { _ in try? await Task.sleep(for: .seconds(60)) })
        c.prepareScene()
        let now = during
        c.scene?.now = { now }
        return c
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func connected() async -> (me: Node, other: Node) {
        let me = node("나"), other = node("민수")
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.settings.memberID]?.nickname == "민수"
            && other.session.members[me.settings.memberID] != nil }
        return (me, other)
    }

    /// Standing on the item puts it in my bag once, tells teammates (an emote now and my presence for later),
    /// shows a banner, and takes it off the map and the minimap.
    func testPickingUpGrantsOnceAndTellsTeammates() async throws {
        let (me, other) = await connected()
        var received: [TeamEmote] = []
        other.session.onEmote = { received.append($1) }
        let suite = prefsSuite()
        let c = controller(me, prefs: suite, start: spawn.tile)
        let scene = try XCTUnwrap(c.scene)
        scene.update(0)
        XCTAssertEqual(granted, [spawn.kind])
        XCTAssertEqual(c.banner, L(.ko).plazaPickedUp(spawn.kind))
        scene.update(0.1); scene.update(0.2)
        XCTAssertEqual(granted, [spawn.kind], "only once")
        XCTAssertNil(scene.itemTile)
        XCTAssertNil(c.minimapItem)
        XCTAssertEqual(PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).pickedItemSlot, spawn.slot)
        await waitUntil { !received.isEmpty && other.session.members[me.settings.memberID]?.pickedItemSlot == spawn.slot }
        XCTAssertEqual(received, [TeamEmote(kind: .pickup, targetMemberID: nil, itemSlot: spawn.slot)])
        XCTAssertEqual(other.session.members[me.settings.memberID]?.pickedItemSlot, spawn.slot)
    }

    /// A teammate's pickup takes the item away here and says who got it. I can't pick it up after them.
    func testATeammatesPickupTakesItAway() async throws {
        let (me, other) = await connected()
        let (from, _) = try XCTUnwrap(beside(spawn.tile))
        let c = controller(me, prefs: prefsSuite(), start: from)
        let scene = try XCTUnwrap(c.scene)
        scene.update(0)
        XCTAssertEqual(scene.itemTile, spawn.tile)
        XCTAssertEqual(c.minimapItem, spawn.tile)
        c.showPickup(from: other.settings.memberID, slot: spawn.slot)
        XCTAssertEqual(c.banner, L(.ko).plazaMemberPickedUp(nickname: "민수", kind: spawn.kind))
        scene.update(0.1)
        XCTAssertNil(scene.itemTile)
        XCTAssertNil(c.minimapItem)
        XCTAssertTrue(granted.isEmpty)
    }

    /// A plaza opened after someone picked the item up learns it from their presence and never shows it.
    func testAPlazaOpenedLaterHidesAnItemAlreadyTaken() async throws {
        let (me, other) = await connected()
        other.session.updatePickedItemSlot(spawn.slot)
        await waitUntil { me.session.members[other.settings.memberID]?.pickedItemSlot == spawn.slot }
        let c = controller(me, prefs: prefsSuite(), start: spawn.tile)
        let scene = try XCTUnwrap(c.scene)
        for _ in 0..<20 { await Task.yield() }
        scene.update(0)
        XCTAssertNil(scene.itemTile)
        XCTAssertTrue(granted.isEmpty, "standing on it gives nothing")
    }

    /// After a restart the item I picked stays gone, and my presence still tells teammates I took it.
    func testMyPickupSurvivesARestart() async throws {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let first = controller(me, prefs: suite, start: spawn.tile)
        first.scene?.update(0)
        XCTAssertEqual(granted.count, 1)
        first.handleClose()
        let restarted = me.session
        restarted.updatePickedItemSlot(nil)   // a fresh session knows nothing
        let again = controller(me, prefs: suite, start: spawn.tile)
        again.scene?.update(0)
        XCTAssertEqual(granted.count, 1, "not again")
        XCTAssertNil(again.scene?.itemTile)
        await waitUntil { other.session.members[me.settings.memberID]?.pickedItemSlot == spawn.slot }
        XCTAssertEqual(other.session.members[me.settings.memberID]?.pickedItemSlot, spawn.slot)
    }

    // MARK: - Bag

    func testAPickedItemGoesInTheBagAndIsSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("items-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(CompanionState()).write(to: url)
        let suite = "items-store-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        func store() -> CompanionStore {
            CompanionStore(provider: OfflineLineProvider(), clock: { Date(timeIntervalSince1970: 1_700_000_000) }, fileURL: url,
                           dittoDisguiseRollingEnabled: false, defaults: UserDefaults(suiteName: suite)!)
        }
        let s = store()
        let candies = s.itemCount(.rareCandy), mints = s.itemCount(.mint)
        s.receivePlazaItem(.rareCandy)
        s.receivePlazaItem(.mint)
        XCTAssertEqual(s.itemCount(.rareCandy), candies + 1)
        XCTAssertEqual(s.itemCount(.mint), mints + 1)
        let reloaded = store()
        XCTAssertEqual(reloaded.itemCount(.rareCandy), candies + 1, "saved")
    }
}
