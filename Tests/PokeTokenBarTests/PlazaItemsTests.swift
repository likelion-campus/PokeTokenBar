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

    /// When the next slot comes, the scene moves on to that slot's item.
    func testTheNextSlotBringsItsOwnItem() throws {
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
        let now = during
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      grantItem: { [weak self] in self?.granted.append($0) },
                                      session: me.session, clock: { now },
                                      bannerSleep: { _ in try? await Task.sleep(for: .seconds(60)) })
        c.prepareScene()
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
        XCTAssertEqual(PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).takenItemSlots, [spawn.slot])
        await waitUntil { !received.isEmpty && other.session.members[me.settings.memberID]?.takenItemSlot == spawn.slot }
        XCTAssertEqual(received, [TeamEmote(kind: .pickup, targetMemberID: nil, itemSlot: spawn.slot)])
        XCTAssertEqual(other.session.members[me.settings.memberID]?.takenItemSlot, spawn.slot)
    }

    /// A teammate's pickup takes the item away here and says who got it. I can't pick it up after them.
    func testATeammatesPickupTakesItAway() async throws {
        let (me, other) = await connected()
        let (from, key) = try XCTUnwrap(beside(spawn.tile))
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
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
        var t = 0.1
        for _ in 0..<30 { t += 1.0 / 60; scene.update(t) }
        XCTAssertEqual(scene.walker.tile, spawn.tile, "I walked onto where it was")
        XCTAssertTrue(granted.isEmpty, "nothing left to pick up")
    }

    /// The pickup banners read naturally for both items, and a picker whose name I don't know yet is "팀원".
    func testPickupBannersReadNaturally() async throws {
        XCTAssertEqual(L(.ko).plazaPickedUp(.rareCandy), "이상한 사탕을 주웠어요! 가방에 넣었어요")
        XCTAssertEqual(L(.ko).plazaPickedUp(.mint), "민트를 주웠어요! 가방에 넣었어요")
        let (me, _) = await connected()
        let (from, _) = try XCTUnwrap(beside(spawn.tile))
        let c = controller(me, prefs: prefsSuite(), start: from)
        let scene = try XCTUnwrap(c.scene)
        scene.update(0)
        XCTAssertEqual(scene.itemTile, spawn.tile)
        c.showPickup(from: "not-in-the-roster-yet", slot: spawn.slot)
        XCTAssertEqual(c.banner, "팀원님이 \(L(.ko).plazaItemObject(spawn.kind)) 주웠어요")
    }

    /// The picker has left, but a teammate who heard the pickup passes it on, so a plaza opened afterwards still
    /// does not show the item.
    func testATakenItemIsPassedOnAfterThePickerLeaves() async throws {
        let picker = node("민수"), relay = node("지영"), late = node("나")
        let pickerLink = hub.connect(picker.transport, to: relay.transport)
        await waitUntil { relay.session.members[picker.settings.memberID] != nil }
        let relayPlaza = controller(relay, prefs: prefsSuite(), start: map.spawn)
        relay.session.onEmote = { [weak relayPlaza] id, emote in
            if emote.kind == .pickup, let slot = emote.itemSlot { relayPlaza?.showPickup(from: id, slot: slot) }
        }
        picker.session.sendEmote(.pickup, target: nil, itemSlot: spawn.slot)
        await waitUntil { relay.session.members.isEmpty == false && relayPlaza.scene?.pickedItemSlots.contains(spawn.slot) == true }
        hub.disconnect(pickerLink)
        await waitUntil { relay.session.members[picker.settings.memberID] == nil }
        hub.connect(late.transport, to: relay.transport)
        await waitUntil { late.session.members[relay.settings.memberID]?.takenItemSlot == spawn.slot }
        let c = controller(late, prefs: prefsSuite(), start: spawn.tile)
        for _ in 0..<20 { await Task.yield() }
        c.scene?.update(0)
        XCTAssertNil(c.scene?.itemTile)
        XCTAssertTrue(granted.isEmpty, "standing where it was gives nothing")
    }

    /// A pickup I heard about is remembered across a restart, even with nobody online afterwards.
    func testAHeardPickupSurvivesARestart() async throws {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let first = controller(me, prefs: suite, start: spawn.tile)
        first.showPickup(from: other.settings.memberID, slot: spawn.slot)
        first.handleClose()
        let alone = node("나")
        let again = controller(alone, prefs: suite, start: spawn.tile)
        again.scene?.update(0)
        XCTAssertNil(again.scene?.itemTile)
        XCTAssertTrue(granted.isEmpty)
    }

    /// A plaza opened after someone picked the item up learns it from their presence and never shows it.
    func testAPlazaOpenedLaterHidesAnItemAlreadyTaken() async throws {
        let (me, other) = await connected()
        other.session.updateTakenItemSlot(spawn.slot)
        await waitUntil { me.session.members[other.settings.memberID]?.takenItemSlot == spawn.slot }
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
        me.session.updateTakenItemSlot(nil)   // as if the session were new and knew nothing
        let again = controller(me, prefs: suite, start: spawn.tile)
        again.scene?.update(0)
        XCTAssertEqual(granted.count, 1, "not again")
        XCTAssertNil(again.scene?.itemTile)
        await waitUntil { other.session.members[me.settings.memberID]?.takenItemSlot == spawn.slot }
        XCTAssertEqual(other.session.members[me.settings.memberID]?.takenItemSlot, spawn.slot)
    }

    /// Only a day of taken slots up to now is kept, so the saved list does not grow forever, plus the next slot that a
    /// teammate whose clock runs a little ahead may already have picked.
    func testOnlyADayOfTakenSlotsIsKept() async {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let c = controller(me, prefs: suite, start: map.spawn)
        for s in (slot - 10)...(slot + 1) { c.showPickup(from: other.settings.memberID, slot: s) }
        XCTAssertEqual(PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).takenItemSlots, Array((slot - 7)...(slot + 1)))
    }

    /// A teammate whose clock runs a day or more ahead tells me about a slot far from now. It must not push out the item
    /// I then pick up: standing on it gives it once, not every frame, and the far slot is neither kept nor passed on.
    func testASlotFarAheadDoesNotUndoMyPickup() async throws {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let c = controller(me, prefs: suite, start: spawn.tile)
        other.session.updateTakenItemSlot(slot + 8)
        await waitUntil { me.session.members[other.settings.memberID]?.takenItemSlot == slot + 8 }
        c.showPickup(from: other.settings.memberID, slot: slot + 8)
        let scene = try XCTUnwrap(c.scene)
        for i in 0..<5 { scene.update(Double(i) / 60) }
        XCTAssertEqual(granted, [spawn.kind], "once, not every frame")
        XCTAssertNil(scene.itemTile)
        XCTAssertEqual(PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).takenItemSlots, [spawn.slot])
        await waitUntil { other.session.members[me.settings.memberID]?.takenItemSlot == spawn.slot }
        XCTAssertEqual(other.session.members[me.settings.memberID]?.takenItemSlot, spawn.slot)
    }

    /// A slot no honest Mac can send (the extremes of Int) is dropped without trapping.
    func testAnImpossibleSlotIsDropped() async {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let c = controller(me, prefs: suite, start: map.spawn)
        c.showPickup(from: other.settings.memberID, slot: .min)
        c.showPickup(from: other.settings.memberID, slot: .max)
        XCTAssertEqual(PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).takenItemSlots, [])
        XCTAssertEqual(c.scene?.pickedItemSlots, [])
    }

    /// A far slot saved while my own clock ran ahead is dropped when the plaza opens, so I pass on my real latest one.
    func testAFarSlotSavedEarlierIsDroppedOnOpen() async {
        let (me, other) = await connected()
        let suite = prefsSuite()
        PlazaPreferences(defaults: UserDefaults(suiteName: suite)!).takenItemSlots = [slot, slot + 8]
        let c = controller(me, prefs: suite, start: map.spawn)
        XCTAssertEqual(c.scene?.pickedItemSlots, [slot])
        await waitUntil { other.session.members[me.settings.memberID]?.takenItemSlot == slot }
        XCTAssertEqual(other.session.members[me.settings.memberID]?.takenItemSlot, slot)
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
