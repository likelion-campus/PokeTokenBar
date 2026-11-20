import AppKit
import XCTest
@testable import PokeTokenBar

/// The Mac edge of the shared key types: `NSEvent` -> `PlazaKeyEvent`, `NSEvent.ModifierFlags` -> `PlazaModifiers`.
@MainActor
final class PlazaInputMappingTests: XCTestCase {
    private func makeScene() -> PlazaScene {
        let map = PlazaMapData.map
        return PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], repeats: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: repeats, keyCode: code))
    }

    /// AppKit marks arrow keys with .numericPad and .function; the scene never read those, so they are dropped.
    func testArrowKeysDropNumericPadAndFunctionFlags() throws {
        for code in [PlazaKeyCode.left, PlazaKeyCode.right, PlazaKeyCode.down, PlazaKeyCode.up] {
            let e = PlazaKeyEvent(try key(code, "\u{F702}", flags: [.numericPad, .function]))
            XCTAssertEqual(e.keyCode, code)
            XCTAssertEqual(e.modifiers, [])
        }
        let shifted = PlazaKeyEvent(try key(PlazaKeyCode.left, "\u{F702}", flags: [.numericPad, .function, .shift, .capsLock]))
        XCTAssertEqual(shifted.modifiers, .shift)
        // Typed: an untyped `[.option]` would pick SetAlgebra's sequence init and test nothing.
        let flags: [(NSEvent.ModifierFlags, PlazaModifiers)] = [
            (.shift, .shift), (.control, .control), (.option, .option), (.command, .command),
            ([.shift, .control, .option, .command, .numericPad, .function, .capsLock, .help], [.shift, .control, .option, .command]),
        ]
        for (ns, plaza) in flags { XCTAssertEqual(PlazaModifiers(ns), plaza, "\(ns)") }
    }

    func testCommandWStillCloses() throws {
        let scene = makeScene()
        var closes = 0
        scene.onCloseRequest = { closes += 1 }
        let host = (scene.stage as! SpriteKitStage).skScene   // the SKScene the SKView sends keys to
        host.keyDown(with: try key(PlazaKeyCode.w, "w", flags: .command))
        XCTAssertEqual(closes, 1)
        host.keyDown(with: try key(PlazaKeyCode.w, "w"))
        XCTAssertEqual(closes, 1, "plain W does not close")
    }

    func testRepeatAndCharactersAreKept() throws {
        let e = PlazaKeyEvent(try key(PlazaKeyCode.z, "z", flags: .option, repeats: true))
        XCTAssertEqual(e, PlazaKeyEvent(keyCode: PlazaKeyCode.z, characters: "z", isRepeat: true, modifiers: .option))
        let plain = PlazaKeyEvent(try key(24, "="))
        XCTAssertEqual(plain, PlazaKeyEvent(keyCode: 24, characters: "=", isRepeat: false, modifiers: []))
    }

    /// The default `currentModifiers` reads the same keyboard state the old `{ NSEvent.modifierFlags }` did.
    func testCurrentModifiersReadsTheSameFlags() {
        XCTAssertEqual(PlatformPlaza.currentModifiers(), PlazaModifiers(NSEvent.modifierFlags))
        let scene = makeScene()
        XCTAssertEqual(scene.currentModifiers(), PlazaModifiers(NSEvent.modifierFlags))
    }

    /// The named codes are the macOS virtual key numbers the scene used before.
    func testKeyCodesAreTheMacVirtualKeys() {
        XCTAssertEqual([PlazaKeyCode.a, PlazaKeyCode.d, PlazaKeyCode.f, PlazaKeyCode.g, PlazaKeyCode.z, PlazaKeyCode.x,
                        PlazaKeyCode.c, PlazaKeyCode.v, PlazaKeyCode.w, PlazaKeyCode.p],
                       [0, 2, 3, 5, 6, 7, 8, 9, 13, 35])
        XCTAssertEqual([PlazaKeyCode.one, PlazaKeyCode.two, PlazaKeyCode.three, PlazaKeyCode.four, PlazaKeyCode.five],
                       [18, 19, 20, 21, 23])
        XCTAssertEqual([PlazaKeyCode.returnKey, PlazaKeyCode.space, PlazaKeyCode.escape, PlazaKeyCode.keypadEnter],
                       [36, 49, 53, 76])
        XCTAssertEqual([PlazaKeyCode.left, PlazaKeyCode.right, PlazaKeyCode.down, PlazaKeyCode.up], [123, 124, 125, 126])
    }
}
