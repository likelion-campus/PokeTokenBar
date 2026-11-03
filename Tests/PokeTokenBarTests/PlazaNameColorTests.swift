import CoreGraphics
import Observation
import XCTest
import SwiftUI
@testable import PokeTokenBar

private struct ColorTestProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["ko": "x", "en": "x"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

private final class FireCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class PlazaNameColorTests: XCTestCase {
    /// A picked colour is shown only when it is one of the palette's; anything else (nothing picked, a value from
    /// another version) falls back to the member's own colour.
    func testPickedColorWinsOnlyWhenItIsInThePalette() {
        let own = PlazaNameColor.hexes[PlazaNameColor.index(forMemberID: "a")]
        let other = PlazaNameColor.hexes.first { $0 != own }!
        XCTAssertEqual(PlazaNameColor.hex(forMemberID: "a", chosen: nil), own)
        XCTAssertEqual(PlazaNameColor.hex(forMemberID: "a", chosen: other), other)
        XCTAssertEqual(PlazaNameColor.hex(forMemberID: "a", chosen: 0x123456), own, "not in the palette")
        let index = PlazaNameColor.hexes.firstIndex(of: other)!
        XCTAssertEqual(rgb(PlazaNameColor.color(forMemberID: "a", chosen: other)), rgb(PlazaNameColor.palette[index]))
        XCTAssertEqual(rgb(PlazaNameColor.color(forMemberID: "a", chosen: 0x123456)), rgb(PlazaNameColor.color(forMemberID: "a")))
    }

    /// The picker is one button; opened, it unfolds every palette colour below it in rows of six.
    @MainActor
    func testPickerUnfoldsThePaletteBelowTheButton() {
        let model = PlazaNameColorModel()
        func size() -> CGSize {
            NSHostingController(rootView: PlazaNameColorPicker(model: model, toggle: {}, choose: { _ in }))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        }
        let closed = size()
        model.isOpen = true
        let open = size()
        let rows = CGFloat((PlazaNameColor.hexes.count + PlazaNameColorPicker.columns - 1) / PlazaNameColorPicker.columns)
        XCTAssertGreaterThanOrEqual(open.height, closed.height + rows * PlazaNameColorPicker.swatch)
        XCTAssertGreaterThanOrEqual(open.width, CGFloat(PlazaNameColorPicker.columns) * PlazaNameColorPicker.swatch)
    }

    private func rgb(_ c: CGColor) -> [CGFloat] {
        let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
        return Array(s.components!.prefix(3))
    }

    func testPaletteHasTwelveDistinctColors() {
        XCTAssertEqual(PlazaNameColor.palette.count, 12)
        let keys = Set(PlazaNameColor.palette.map { rgb($0).map { Int(($0 * 255).rounded()) } })
        XCTAssertEqual(keys.count, 12)
        XCTAssertEqual(rgb(PlazaNameColor.palette[0]).map { Int(($0 * 255).rounded()) }, [255, 255, 255])
        XCTAssertEqual(rgb(PlazaNameColor.palette[11]).map { Int(($0 * 255).rounded()) }, [168, 200, 255])
    }

    func testIndexIsStableAcrossProcesses() {
        XCTAssertEqual(2166136261 % 12, 1)
        XCTAssertEqual(3826002220 % 12, 4)
        XCTAssertEqual(PlazaNameColor.index(forMemberID: ""), 1)
        XCTAssertEqual(PlazaNameColor.index(forMemberID: "a"), 4)
    }

    func testColorComesFromPaletteAndDiffersBetweenSomeMembers() {
        let ids = (0..<30).map { "member-\($0)" }
        let indices = Set(ids.map { PlazaNameColor.index(forMemberID: $0) })
        XCTAssertGreaterThan(indices.count, 3)
        for id in ids {
            XCTAssertTrue((0..<12).contains(PlazaNameColor.index(forMemberID: id)))
            XCTAssertEqual(rgb(PlazaNameColor.color(forMemberID: id)),
                           rgb(PlazaNameColor.palette[PlazaNameColor.index(forMemberID: id)]))
        }
    }

    @MainActor func testRepresentativeSubjectChangeIsObservable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("namecolor-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion-state.json")
        var state = CompanionState()
        state.dex = [DexEntry(baseID: 25, finalID: 25, chainOrder: [25], rarity: .common,
                              caughtAt: Date(timeIntervalSince1970: 1_700_000_000), isShiny: false, nature: .brave,
                              names: [25: ["ko": "x", "en": "x"]], form: nil)]
        try JSONEncoder().encode(state).write(to: url)
        let suite = "namecolor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CompanionStore(provider: ColorTestProvider(), clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                   fileURL: url, rng: SeededRNG(seed: 7),
                                   dittoDisguiseRollingEnabled: false, defaults: defaults)
        XCTAssertNil(store.representativeSubject.speciesID)
        let fired = FireCount()
        withObservationTracking({ _ = store.representativeSubject }, onChange: { fired.hit() })
        XCTAssertTrue(store.setRepresentativeSpeciesID(25))
        XCTAssertEqual(fired.value, 1)
        XCTAssertEqual(store.representativeSubject.speciesID, 25)
    }
}
