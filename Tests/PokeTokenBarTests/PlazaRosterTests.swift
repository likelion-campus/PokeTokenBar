import XCTest
import SwiftUI
@testable import PokeTokenBar

final class PlazaRosterTests: XCTestCase {
    private func entry(_ id: String, _ nick: String, presence: PlazaPresence = .online, me: Bool = false) -> PlazaRosterEntry {
        PlazaRosterEntry(id: id, nickname: nick, speciesID: 25, speciesName: "x", gender: nil,
                         isShiny: false, presence: presence, isMe: me)
    }

    func testSortOrderMeOnlineIdleAsleep() {
        let list = [entry("a", "다람", presence: .asleep), entry("b", "나무"), entry("c", "가지", presence: .idle),
                    entry("d", "하늘"), entry("e", "가람", presence: .asleep), entry("f", "바다", presence: .idle),
                    entry("me", "힘", presence: .idle, me: true)]
        XCTAssertEqual(PlazaRoster.sorted(list).map(\.id), ["me", "b", "d", "c", "f", "e", "a"])
    }

    func testMyEntryFollowsRaisedPinnedAndEgg() {
        let raised = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: 4, isShiny: true),
                                         followsRaised: true, raisedName: "파이리", raisedGender: .female,
                                         pinnedName: nil, eggName: "알")
        XCTAssertEqual(raised.speciesID, 4); XCTAssertEqual(raised.speciesName, "파이리")
        XCTAssertEqual(raised.gender, .female); XCTAssertTrue(raised.isShiny)
        XCTAssertTrue(raised.isMe); XCTAssertEqual(raised.presence, .online); XCTAssertEqual(raised.id, "m")

        let pinned = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: 25, isShiny: false),
                                         followsRaised: false, raisedName: "파이리", raisedGender: .female,
                                         pinnedName: "피카츄", eggName: "알")
        XCTAssertEqual(pinned.speciesID, 25); XCTAssertEqual(pinned.speciesName, "피카츄"); XCTAssertNil(pinned.gender)

        let egg = PlazaRoster.myEntry(memberID: "m", nickname: "나", subject: .init(speciesID: nil, isShiny: false),
                                      followsRaised: true, raisedName: "Token Egg", raisedGender: nil,
                                      pinnedName: nil, eggName: "알")
        XCTAssertNil(egg.speciesID); XCTAssertEqual(egg.speciesName, "알"); XCTAssertNil(egg.gender)
    }

    @MainActor func testMyEntryFromEggStoreUsesTeamSettings() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-roster-\(UUID().uuidString).json")
        let companion = CompanionStore(fileURL: url)
        let name = "plaza.roster.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = TeamSettings(defaults: UserDefaults(suiteName: name)!)
        settings.nickname = " 도토리 "
        let entry = PlazaRoster.myEntry(companion: companion, teamSettings: settings)
        XCTAssertEqual(entry.id, settings.memberID)
        XCTAssertEqual(entry.nickname, "도토리")
        XCTAssertNil(entry.speciesID)
        XCTAssertEqual(entry.speciesName, L(.ko).plazaEggName)
        XCTAssertTrue(entry.isMe)
    }

    func testIconURL() {
        XCTAssertEqual(PlazaIconLoader.url(speciesID: 25).absoluteString,
            "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-vii/icons/25.png")
    }

    func testRosterStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.plazaRosterTitle, "팀원"); XCTAssertEqual(l.plazaStatusOnline, "접속")
        XCTAssertEqual(l.plazaStatusIdle, "자리비움"); XCTAssertEqual(l.plazaStatusAsleep, "잠")
        XCTAssertEqual(l.plazaEggName, "알")
        XCTAssertEqual(l.plazaRosterCount(online: 3, total: 5), "접속 3 / 5")
        XCTAssertEqual(l.plazaAwaySuffix, "zZ")
    }
}

extension PlazaRosterTests {
    func testCharacterForTeamKeepsNameGenderAndDropsEggDetails() {
        let entry = PlazaRosterEntry(id: "m", nickname: "나", speciesID: 4, speciesName: "파이리", gender: .female,
                                     isShiny: true, presence: .online, isMe: true)
        let c = PlazaRoster.character(entry: entry, subject: .init(speciesID: 4, isShiny: true, form: nil))
        XCTAssertEqual(c, TeamMonSummary(speciesID: 4, isShiny: true, form: nil, speciesName: "파이리", gender: .female))
        let egg = PlazaRosterEntry(id: "m", nickname: "나", speciesID: nil, speciesName: "알", gender: nil,
                                   isShiny: false, presence: .online, isMe: true)
        let e = PlazaRoster.character(entry: egg, subject: .init(speciesID: nil, isShiny: false))
        XCTAssertEqual(e, TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil))
    }

    private func member(_ id: String, _ nick: String, inPlaza: Bool, isIdle: Bool = false, speciesID: Int? = 25,
                        name: String? = "Pikachu") -> TeamMemberState {
        TeamMemberState(memberID: id, nickname: nick,
                        character: TeamMonSummary(speciesID: speciesID, isShiny: true, form: nil, speciesName: name, gender: .female),
                        inPlaza: inPlaza, tile: nil, facing: nil, isWalking: false, isIdle: isIdle)
    }

    func testEntriesSortMeOnlineIdleAsleep() {
        let me = entry("me", "힘", me: true)
        let list = PlazaRoster.entries(me: me, members: [member("a", "다람", inPlaza: false), member("b", "나무", inPlaza: true),
                                                         member("c", "가지", inPlaza: true, isIdle: true)],
                                       asleep: [member("d", "가람", inPlaza: true)])
        XCTAssertEqual(list.map(\.id), ["me", "b", "a", "c", "d"])
        XCTAssertEqual(list.map(\.presence), [.online, .online, .online, .idle, .asleep])
        XCTAssertEqual(PlazaRoster.entries(me: nil, members: [member("b", "나무", inPlaza: true)]).map(\.id), ["b"])
    }

    /// A teammate working with the plaza closed is online (the report: "일하는데 '잠'"). Only no input makes them idle.
    func testPlazaClosedIsOnlineAndOnlyNoInputIsIdle() {
        let list = PlazaRoster.entries(me: nil, members: [member("a", "다람", inPlaza: false), member("b", "나무", inPlaza: true),
                                                          member("c", "가지", inPlaza: false, isIdle: true)])
        XCTAssertEqual(list.first { $0.id == "a" }?.presence, .online)
        XCTAssertEqual(list.first { $0.id == "b" }?.presence, .online)
        XCTAssertEqual(list.first { $0.id == "c" }?.presence, .idle, "idle with the plaza closed too")
        let a = list.first { $0.id == "a" }
        XCTAssertEqual(a?.nickname, "다람"); XCTAssertEqual(a?.speciesID, 25); XCTAssertEqual(a?.speciesName, "Pikachu")
        XCTAssertEqual(a?.gender, .female); XCTAssertEqual(a?.isShiny, true); XCTAssertEqual(a?.isMe, false)
        let egg = PlazaRoster.entries(me: nil, members: [member("e", "알", inPlaza: true, speciesID: nil, name: nil)])
        XCTAssertEqual(egg.first?.speciesName, L(.ko).plazaEggName)
    }

    func testFocusBadgeBeatsIdleButNotAsleep() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func focused(_ id: String, _ nick: String, ends: Date, idle: Bool = false) -> TeamMemberState {
            var m = member(id, nick, inPlaza: true, isIdle: idle); m.focusEndsAt = ends; return m
        }
        let me = entry("me", "힘", me: true)
        let list = PlazaRoster.entries(
            me: me, meIsFocusing: true,
            members: [focused("a", "가지", ends: now.addingTimeInterval(60), idle: true),
                      focused("b", "나무", ends: now.addingTimeInterval(-1)),
                      member("c", "다람", inPlaza: true)],
            asleep: [focused("d", "가람", ends: now.addingTimeInterval(60))], now: now)
        func presence(_ id: String) -> PlazaPresence? { list.first { $0.id == id }?.presence }
        XCTAssertEqual(presence("me"), .focus)
        XCTAssertEqual(presence("a"), .focus, "focus beats idle")
        XCTAssertEqual(presence("b"), .online, "expired focus")
        XCTAssertEqual(presence("d"), .asleep, "asleep beats focus")
        XCTAssertEqual(list.map(\.id), ["me", "a", "b", "c", "d"], "focus sorts with online by nickname")
    }

    func testFocusBadgeText() {
        XCTAssertEqual(PlazaPresence.focus.badge.text, "🔥집중")
        XCTAssertEqual(PlazaPresence.focus.badge.color, 0xD9502A)
    }

    /// My own row follows my own input: it used to say 접속 forever.
    func testMyRowShowsMyIdle() {
        let me = entry("me", "힘", me: true)
        XCTAssertEqual(PlazaRoster.entries(me: me, members: []).first?.presence, .online)
        let idle = PlazaRoster.entries(me: me, meIsIdle: true, members: [member("b", "나무", inPlaza: true)])
        XCTAssertEqual(idle.map(\.id), ["me", "b"], "I stay first")
        XCTAssertEqual(idle.first?.presence, .idle)
        XCTAssertEqual(idle.first?.isMe, true)
    }

    /// A teammate who disconnected shows as 잠 with their last character; once connected again, only the live row stays.
    func testAsleepTeammateShowsUntilTheyConnect() {
        let asleep = member("a", "다람", inPlaza: true)
        let list = PlazaRoster.entries(me: nil, members: [], asleep: [asleep])
        XCTAssertEqual(list.map(\.presence), [.asleep])
        XCTAssertEqual(list.first?.speciesName, "Pikachu")
        let both = PlazaRoster.entries(me: nil, members: [member("a", "다람", inPlaza: false)], asleep: [asleep])
        XCTAssertEqual(both.map(\.presence), [.online])
    }

    @MainActor func testPageFitsAboveTheClock() {
        let m = PlazaRosterMetrics.self
        func height(_ slots: Int) -> CGFloat {
            m.margin + m.bottomClearance + 2 * m.padding + m.headerHeight + m.listTopPadding
                + CGFloat(slots) * m.slotHeight + CGFloat(slots - 1) * m.slotSpacing
        }
        XCTAssertEqual(PlazaRoster.capacity(forHeight: height(4)), 4)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: height(4) - 1), 3, "one point short loses a slot")
        XCTAssertEqual(PlazaRoster.capacity(forHeight: height(4) + 47), 4)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: height(4) + 48), 5)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 640), 6, "the default window shows a full party")
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 2000), 6, "a tall window still stops at six")
        XCTAssertEqual(PlazaRoster.capacity(forHeight: PlazaWindowController.minContentSize.height), 2, "the smallest window")
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 0), 1, "a page is never empty")
    }

    func testPagesSplitTheSortedListBySix() {
        let entries = PlazaRoster.sorted([entry("me", "나", me: true)]
            + (0..<5).map { entry("o\($0)", "온\($0)") } + (0..<4).map { entry("a\($0)", "잠\($0)", presence: .asleep) })
        let first = PlazaRoster.page(entries, index: 0, size: 6)
        XCTAssertEqual(first.shown.map(\.id), ["me", "o0", "o1", "o2", "o3", "o4"])
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.count, 2)
        let second = PlazaRoster.page(entries, index: 1, size: 6)
        XCTAssertEqual(second.shown.map(\.id), ["a0", "a1", "a2", "a3"], "asleep teammates sort to the last page")
        XCTAssertEqual(second.index, 1)
    }

    func testTheSeventhPersonAddsAPage() {
        let six = (0..<6).map { entry("m\($0)", "멤버\($0)") }
        XCTAssertEqual(PlazaRoster.page(six, index: 0, size: 6).count, 1)
        XCTAssertEqual(PlazaRoster.page(six + [entry("m6", "멤버6")], index: 0, size: 6).count, 2)
        XCTAssertEqual(PlazaRoster.page([], index: 0, size: 6).count, 1)
        XCTAssertEqual(PlazaRoster.page([], index: 0, size: 6).shown, [])
    }

    func testPageFallsBackWhenItsPeopleLeave() {
        let seven = (0..<7).map { entry("m\($0)", "멤버\($0)") }
        let page = PlazaRoster.page(seven, index: 5, size: 6)
        XCTAssertEqual(page.index, 1)
        XCTAssertEqual(page.shown.map(\.id), ["m6"])
        XCTAssertEqual(PlazaRoster.page(Array(seven.prefix(6)), index: 1, size: 6).index, 0)
    }

    @MainActor func testTurningPagesStopsAtTheEnds() {
        let model = PlazaRosterModel()
        model.entries = (0..<13).map { entry("m\($0)", "멤버\($0)") }
        model.turnPage(by: -1)
        XCTAssertEqual(model.page, 0)
        model.turnPage(by: 1)
        model.turnPage(by: 1)
        XCTAssertEqual(model.page, 2)
        model.turnPage(by: 1)
        XCTAssertEqual(model.page, 2)
        model.entries = Array(model.entries.prefix(7))
        model.turnPage(by: -1)
        XCTAssertEqual(model.page, 0, "turning starts from the page on screen, not the one that went away")
    }

    @MainActor func testIconStaysInMemoryAfterTheFirstLoad() async throws {
        let id = 987_654
        let png = try XCTUnwrap(Self.solidPNG(red: 1))
        var loads = 0
        XCTAssertNil(PlazaIconLoader.cachedIcon(speciesID: id))
        let first = await PlazaIconLoader.icon(speciesID: id) { _ in loads += 1; return png }
        XCTAssertNotNil(first)
        let second = await PlazaIconLoader.icon(speciesID: id) { _ in loads += 1; return nil }
        XCTAssertTrue(second === first)
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(PlazaIconLoader.cachedIcon(speciesID: id) === first)
    }

    @MainActor func testFailedIconIsNotRemembered() async {
        let id = 987_655
        let missing = await PlazaIconLoader.icon(speciesID: id) { _ in nil }
        XCTAssertNil(missing)
        XCTAssertNil(PlazaIconLoader.cachedIcon(speciesID: id))
    }

    /// Turning a page mounts new rows. A remembered icon must be there on the first frame, not after a blank one.
    @MainActor func testRememberedIconDrawsOnTheFirstFrame() async throws {
        let id = 987_656
        let png = try XCTUnwrap(Self.solidPNG(red: 1))
        _ = await PlazaIconLoader.icon(speciesID: id) { _ in png }
        let model = PlazaRosterModel()
        model.entries = [PlazaRosterEntry(id: "a", nickname: "a", speciesID: id, speciesName: "x", gender: nil,
                                          isShiny: false, presence: .idle, isMe: false)]
        let renderer = ImageRenderer(content: PlazaRosterView(model: model))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: image)
        let m = PlazaRosterMetrics.self
        let y = Int(m.padding + m.headerHeight + m.listTopPadding + m.slotHeight / 2)
        let color = try XCTUnwrap(rep.colorAt(x: Int(m.padding) + 26, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.2, "the icon, not the blank placeholder")
    }

    static func solidPNG(red: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        for x in 0..<40 { for y in 0..<30 { rep?.setColor(NSColor(deviceRed: red, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return rep?.representation(using: .png, properties: [:])
    }
}
