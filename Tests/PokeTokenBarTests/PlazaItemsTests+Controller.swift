import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaItemsTests {


    private func controller(_ me: Node, prefs suite: String, start: TilePoint) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: suite))
        prefs.saveLastTile(start)
        let now = during
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      grantItem: { [weak self] in self?.granted.append($0) },
                                      session: me.session, clock: { now },
                                      bannerSleep: { _ in try? await Task.sleep(for: .seconds(60)) },
                                      shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
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
        XCTAssertEqual(c.activity.pickups, 1, "today's count")
        XCTAssertEqual(c.banner, L(.ko).plazaPickedUp(spawn.kind))
        scene.update(0.1); scene.update(0.2)
        XCTAssertEqual(granted, [spawn.kind], "only once")
        XCTAssertEqual(c.activity.pickups, 1, "once")
        XCTAssertNil(scene.itemTile)
        XCTAssertNil(c.minimapItem)
        XCTAssertEqual(PlazaPreferences(defaults: TestDefaults.make(suite: suite)).takenItemSlots, [spawn.slot])
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
        XCTAssertEqual(c.activity.pickups, 0, "a teammate's pickup is not mine")
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

    /// Only the last few taken slots up to now are kept, so the saved list does not grow forever, plus the next slot that
    /// a teammate whose clock runs a little ahead may already have picked.
    func testOnlyTheLastFewTakenSlotsAreKept() async {
        let (me, other) = await connected()
        let suite = prefsSuite()
        let c = controller(me, prefs: suite, start: map.spawn)
        for s in (slot - 10)...(slot + 1) { c.showPickup(from: other.settings.memberID, slot: s) }
        XCTAssertEqual(PlazaPreferences(defaults: TestDefaults.make(suite: suite)).takenItemSlots, Array((slot - 7)...(slot + 1)))
    }

    /// A teammate whose clock runs hours ahead tells me about a slot far from now. It must not push out the item
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
        XCTAssertEqual(PlazaPreferences(defaults: TestDefaults.make(suite: suite)).takenItemSlots, [spawn.slot])
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
        XCTAssertEqual(PlazaPreferences(defaults: TestDefaults.make(suite: suite)).takenItemSlots, [])
        XCTAssertEqual(c.scene?.pickedItemSlots, [])
    }

    /// A far slot saved while my own clock ran ahead is dropped when the plaza opens, so I pass on my real latest one.
    func testAFarSlotSavedEarlierIsDroppedOnOpen() async {
        let (me, other) = await connected()
        let suite = prefsSuite()
        PlazaPreferences(defaults: TestDefaults.make(suite: suite)).takenItemSlots = [slot, slot + 8]
        let c = controller(me, prefs: suite, start: map.spawn)
        XCTAssertEqual(c.scene?.pickedItemSlots, [slot])
        await waitUntil { other.session.members[me.settings.memberID]?.takenItemSlot == slot }
        XCTAssertEqual(other.session.members[me.settings.memberID]?.takenItemSlot, slot)
    }
}
