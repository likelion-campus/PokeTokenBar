import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

private struct OfflineLineProvider: PokeProviding {
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw CancellationError() }
}

/// Plaza items: a rare candy or a mint now and then, the same everywhere, picked up by whoever steps on it.
@MainActor
final class PlazaItemsTests: XCTestCase {
    let map = PlazaMapData.map
    /// The tiles slots pick from: the frozen item layout, the same on every version.
    private var candidates: [TilePoint] { PlazaItems.spawnCandidates }
    private var openTiles: Set<TilePoint> { PlazaItems.openTiles(in: map) }
    /// A slot whose item is up, and a moment while it is.
    let slot = 160_000
    var spawn: PlazaItems.Spawn { PlazaItems.spawn(slot: slot, candidates: candidates)! }
    var during: Date { spawn.appearsAt.addingTimeInterval(60) }

    // MARK: - Rules

    func testCandidatesAreOpenGroundOnly() async {
        let shelter = Set(map.shelterTiles)
        let open = PlazaItems.candidates(in: map)
        XCTAssertFalse(open.isEmpty)
        for t in open {
            XCTAssertTrue(map.isWalkable(t))
            XCTAssertFalse(shelter.contains(t), "\(t) is in the shelter")
            XCTAssertFalse([PlazaDirection.up, .down, .left, .right].contains { map.tile(at: PlazaWalker.offset(t, $0)) == .board },
                           "\(t) is next to the sign")
        }
    }

    /// Every slot of twenty minutes drops one item, at a minute within its first ten, on an open tile, and it
    /// stays until the slot ends. The same slot gives the same item on every Mac.
    func testEachSlotDropsOneItemTheSameEverywhere() async {
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
        XCTAssertEqual(PlazaItems.slotLength, 20 * 60, "one item every twenty minutes: a reason to drop by often")
        XCTAssertEqual(PlazaItems.appearWindow, 10 * 60, "it lies for at least ten minutes")
        XCTAssertEqual(PlazaItems.candyShare, 0.8, "mostly rare candies")
    }

    func testTheItemIsUpFromItsMinuteUntilTheSlotEndsUnlessPicked() async {
        let s = spawn
        XCTAssertNil(PlazaItems.current(at: s.appearsAt.addingTimeInterval(-1), candidates: candidates, picked: []))
        XCTAssertEqual(PlazaItems.current(at: s.appearsAt, candidates: candidates, picked: []), s)
        XCTAssertEqual(PlazaItems.current(at: s.endsAt.addingTimeInterval(-1), candidates: candidates, picked: []), s)
        XCTAssertNotEqual(PlazaItems.current(at: s.endsAt, candidates: candidates, picked: [])?.slot, s.slot, "gone when the slot ends")
        XCTAssertNil(PlazaItems.current(at: during, candidates: candidates, picked: [s.slot]))
    }

    // MARK: - Scene

    func scene(on tile: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: tile, zoom: 2, nickname: "나")
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        let now = during
        s.now = { now }
        return s
    }

    func beside(_ t: TilePoint) -> (TilePoint, UInt16)? {
        let options: [(PlazaDirection, UInt16)] = [(.left, 124), (.right, 123), (.up, 125), (.down, 126)]
        for (side, key) in options {
            let from = PlazaWalker.offset(t, side)
            if map.isWalkable(from) { return (from, key) }
        }
        return nil
    }

    /// The item lies on its tile; walking onto it reports the pickup, and once picked it is gone.
    func testWalkingOntoTheItemPicksItUp() async throws {
        let (from, key) = try XCTUnwrap(beside(spawn.tile))
        let s = scene(on: from)
        var picked: [PlazaItems.Spawn] = []
        s.onItemPickup = { picked.append($0) }
        s.update(0)
        XCTAssertEqual(s.itemTile, spawn.tile)
        XCTAssertTrue(picked.isEmpty)
        s.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        s.handleKeyUp(keyCode: key)
        var t = 1.0 / 60
        s.update(t)
        XCTAssertEqual(s.walker.tile, spawn.tile, "the step onto it has begun")
        XCTAssertTrue(picked.isEmpty, "not yet: the character is still mostly on the tile before")
        while picked.isEmpty && t < 1 { t += 1.0 / 60; s.update(t) }
        XCTAssertGreaterThanOrEqual(t, PlazaWalker.stepDuration / 2, "picked once over half way")
        XCTAssertEqual(picked.first, spawn)
        s.pickedItemSlots = [spawn.slot]
        s.update(t + 0.1)
        XCTAssertNil(s.itemTile, "picked, so gone")
    }

    func testNoItemBeforeItsMinuteOrWithTheBackgroundHidden() async {
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

    /// When the next slot comes, the scene moves on to that slot's item.
    func testTheNextSlotBringsItsOwnItem() async throws {
        let next = try XCTUnwrap(PlazaItems.spawn(slot: slot + 1, candidates: candidates))
        XCTAssertNotEqual(next.tile, spawn.tile, "test precondition")
        let s = scene(on: map.spawn)
        s.update(0)
        XCTAssertEqual(s.itemTile, spawn.tile)
        let later = next.appearsAt.addingTimeInterval(60)
        s.now = { later }
        s.update(0.1)
        XCTAssertEqual(s.itemTile, next.tile)
    }

    // MARK: - Team

    var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    var granted: [ItemKind] = []

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        granted = []
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
    }

    func node(_ name: String) -> Node {
        let suite = "plaza.items.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
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

    func prefsSuite() -> String {
        let name = "plaza.items.prefs.\(UUID())"
        return name
    }

    // MARK: - Bag

    func testAPickedItemGoesInTheBagAndIsSaved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("items-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(CompanionState()).write(to: url)
        let suite = "items-store-\(UUID().uuidString)"
        func store() -> CompanionStore {
            CompanionStore(provider: OfflineLineProvider(), clock: { Date(timeIntervalSince1970: 1_700_000_000) }, fileURL: url,
                           dittoDisguiseRollingEnabled: false, defaults: TestDefaults.make(suite: suite))
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

    /// Every earlier version picks its spot from the same frozen layout, so the pit, sign and shelter moving changes nothing.
    func testTheMoveKeepsTheItemSpotsOfEarlierVersions() async {
        XCTAssertEqual(candidates.count, 1062)
        let expected = [(34, 22), (41, 3), (39, 14), (37, 4), (12, 12)]
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(PlazaItems.spawn(slot: 160_000 + i, candidates: candidates)?.tile, TilePoint(x: e.0, y: e.1))
        }
    }

    /// First slot at or after 160_000 whose frozen-layout tile satisfies `where`.
    private func slotWhere(_ predicate: (TilePoint) -> Bool) throws -> PlazaItems.Spawn {
        for n in 160_000..<4_000_000 {
            if let s = PlazaItems.spawn(slot: n, candidates: candidates), predicate(s.tile) { return s }
        }
        throw XCTSkip("no slot found")
    }

    /// The new pit sits inside the old sign and shelter, which no slot ever picks, so no item can land in the fire.
    func testNoSlotCanPickAFireTile() async {
        for t in map.campfireTiles { XCTAssertFalse(candidates.contains(t), "\(t)") }
    }

    func testAnItemWhoseSpotIsNowTheSignOrTheShelterIsNotShown() async throws {
        let board = Set([PlazaDirection.up, .down, .left, .right].map { PlazaWalker.offset(map.boardTile, $0) })
        let blocked: [(String, (TilePoint) -> Bool)] = [
            ("sign", { $0 == self.map.boardTile }),
            ("shelter", { self.map.shelterTiles.contains($0) }),
            ("next to the sign", { board.contains($0) && self.map.isWalkable($0) && !self.map.shelterTiles.contains($0) }),
        ]
        for (name, predicate) in blocked {
            let item = try slotWhere(predicate)
            XCTAssertFalse(PlazaItems.isShown(item, openTiles: openTiles), name)
            let s = scene(on: map.spawn)
            let at = item.appearsAt.addingTimeInterval(60)
            s.now = { at }
            s.update(0)
            XCTAssertNil(s.itemTile, name)
        }
    }

    func testAnItemWhoseSpotIsStillOpenIsShownThere() async {
        XCTAssertTrue(PlazaItems.isShown(spawn, openTiles: openTiles), "test precondition: the default slot is on open ground")
        let s = scene(on: map.spawn)
        s.now = { self.during }
        s.update(0)
        XCTAssertEqual(s.itemTile, spawn.tile)
    }

    func testAnItemInTallGrassIsStillShown() async throws {
        let item = try slotWhere { self.map.tile(at: $0) == .tallGrass }
        XCTAssertTrue(PlazaItems.isShown(item, openTiles: openTiles))
    }
}
