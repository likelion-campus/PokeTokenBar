#if os(Windows)
import CPlazaD2D
import WinSDK
import XCTest
@testable import PokeTokenBar

/// D7: the Win32 input of the plaza window as the shared input types. Pure functions, no window.
@MainActor final class WindowsPlazaInputTests: XCTestCase {
    private let everyPlazaKeyCode: [(String, UInt16)] = [
        ("a", PlazaKeyCode.a), ("d", PlazaKeyCode.d), ("f", PlazaKeyCode.f), ("g", PlazaKeyCode.g), ("z", PlazaKeyCode.z),
        ("x", PlazaKeyCode.x), ("c", PlazaKeyCode.c), ("v", PlazaKeyCode.v), ("w", PlazaKeyCode.w), ("1", PlazaKeyCode.one),
        ("2", PlazaKeyCode.two), ("3", PlazaKeyCode.three), ("4", PlazaKeyCode.four), ("5", PlazaKeyCode.five),
        ("p", PlazaKeyCode.p), ("return", PlazaKeyCode.returnKey), ("space", PlazaKeyCode.space), ("escape", PlazaKeyCode.escape),
        ("keypadEnter", PlazaKeyCode.keypadEnter), ("left", PlazaKeyCode.left), ("right", PlazaKeyCode.right),
        ("down", PlazaKeyCode.down), ("up", PlazaKeyCode.up),
        ("-", 27), ("=", 24),  // the keys the scene matches by characters
    ]

    func testEveryPlazaKeyCodeHasAScanCode() async {
        for (name, code) in everyPlazaKeyCode {
            guard let key = WinPlazaInput.scanCode(forMacKeyCode: code) else { XCTFail("no scan code for \(name)"); continue }
            XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: key.scan, extended: key.extended), code, name)
        }
        // known positions: W = 0x11, A = 0x1E, arrows and keypad Enter are extended, Enter is not
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x11, extended: false), PlazaKeyCode.w)
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x1E, extended: false), PlazaKeyCode.a)
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x1C, extended: false), PlazaKeyCode.returnKey)
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x1C, extended: true), PlazaKeyCode.keypadEnter)
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x4B, extended: true), PlazaKeyCode.left)
        XCTAssertNil(WinPlazaInput.macKeyCode(scanCode: 0x2A, extended: false), "Shift is not a key the scene names")
        XCTAssertNil(WinPlazaInput.macKeyCode(scanCode: 0x3B, extended: false), "F1")
    }

    func testNumpadArrowsWithNumLockOffAreArrowsAndWithItOnAreDigits() async {
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x48, extended: false, virtualKey: 0x26), PlazaKeyCode.up)
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x4D, extended: false, virtualKey: 0x27), PlazaKeyCode.right)
        let digit = WinPlazaInput.macKeyCode(scanCode: 0x48, extended: false, virtualKey: 0x68 /* VK_NUMPAD8 */)
        XCTAssertEqual(digit, 91)
        XCTAssertNotEqual(digit, PlazaKeyCode.up)
    }

    func testAKeyTheImeTookIsStillTheSameKey() async {
        // VK_PROCESSKEY (0xE5) with W's scan code: the position decides.
        let bits = WinPlazaInput.KeyBits(lParam: LPARAM(0x11 << 16))
        let e = WinPlazaInput.event(bits: bits, virtualKey: 0xE5, modifiers: [], characters: nil)
        XCTAssertEqual(e?.keyCode, PlazaKeyCode.w)
    }

    func testRepeatBit() async {
        let first = WinPlazaInput.KeyBits(lParam: LPARAM((0x4B << 16) | (1 << 24) | 1))
        XCTAssertFalse(first.isRepeat)
        XCTAssertEqual(first.scanCode, 0x4B)
        XCTAssertTrue(first.extended)
        let again = WinPlazaInput.KeyBits(lParam: LPARAM((0x4B << 16) | (1 << 24) | (1 << 30) | 1))
        XCTAssertTrue(again.isRepeat)
        XCTAssertFalse(again.isRelease)
        let up = WinPlazaInput.KeyBits(lParam: LPARAM(Int(truncatingIfNeeded: (0x4B << 16) | (1 << 24) | (1 << 30) | (1 << 31) | 1)))
        XCTAssertTrue(up.isRelease)
        XCTAssertEqual(WinPlazaInput.event(bits: again, virtualKey: 0x25, modifiers: [], characters: nil)?.isRepeat, true)
        XCTAssertEqual(WinPlazaInput.event(bits: first, virtualKey: 0x25, modifiers: [], characters: nil)?.isRepeat, false)
    }

    func testCtrlIsCommandAndControl() async {
        func mods(_ down: Set<Int32>) -> PlazaModifiers { WinPlazaInput.modifiers { down.contains($0) } }
        XCTAssertEqual(mods([]), [])
        XCTAssertEqual(mods([0x11, 0xA2]), [.command, .control])
        XCTAssertEqual(mods([0x11, 0xA3]), [.command, .control], "right Ctrl too")
        XCTAssertEqual(mods([0x10, 0xA0]), [.shift])
        XCTAssertEqual(mods([0x12, 0xA4]), [.option])
        XCTAssertEqual(mods([0x10, 0x11, 0x12]), [.shift, .command, .control, .option])
        XCTAssertEqual(mods([0x5B]), [], "the Windows key is nothing")
    }

    func testAltGrIsNotTheCtrlChord() async {
        func mods(_ down: Set<Int32>) -> PlazaModifiers { WinPlazaInput.modifiers { down.contains($0) } }
        // AltGr = left Ctrl + right Alt (the system reports both Ctrl and Alt as down)
        XCTAssertEqual(mods([0x11, 0xA2, 0x12, 0xA5]), [.option])
        // a real Ctrl+left Alt is a chord
        XCTAssertEqual(mods([0x11, 0xA2, 0x12, 0xA4]), [.command, .control, .option])
        // right Ctrl with right Alt is not AltGr either
        XCTAssertEqual(mods([0x11, 0xA3, 0x12, 0xA5]), [.command, .control, .option])
    }

    func testWheelNotchIsThreeLinesOfTenPoints() async {
        let notch = WinPlazaInput.wheel(delta: 120, horizontal: false, linesPerNotch: 3)
        XCTAssertEqual(notch.dy, 30)
        XCTAssertEqual(notch.dx, 0)
        XCTAssertEqual(WinPlazaInput.wheel(delta: -120, horizontal: false, linesPerNotch: 3).dy, -30)
        XCTAssertEqual(WinPlazaInput.wheel(delta: 120, horizontal: false, linesPerNotch: 1).dy, 10, "the system's lines per notch")
        // a precision touchpad's small deltas add up to the same distance
        let small = (0..<8).reduce(CGFloat(0)) { $0 + WinPlazaInput.wheel(delta: 15, horizontal: false, linesPerNotch: 3).dy }
        XCTAssertEqual(small, 30)
    }

    func testHorizontalWheelSign() async {
        XCTAssertEqual(WinPlazaInput.wheel(delta: 120, horizontal: true, linesPerNotch: 3).dx, -30, "Windows: positive is right; AppKit's dx is the opposite")
        XCTAssertEqual(WinPlazaInput.wheel(delta: -120, horizontal: true, linesPerNotch: 3).dx, 30)
        XCTAssertEqual(WinPlazaInput.wheel(delta: 120, horizontal: true, linesPerNotch: 3).dy, 0)
    }

    func testPointsAreClientPixelsOverTheScale() async {
        for dpi: UInt32 in [96, 120, 144, 192] {
            let p = WinPlazaInput.point(clientX: 300, clientY: 150, dpi: dpi)
            XCTAssertEqual(p.x, 300 * 96 / CGFloat(dpi), accuracy: 0.0001, "dpi \(dpi)")
            XCTAssertEqual(p.y, 150 * 96 / CGFloat(dpi), accuracy: 0.0001, "dpi \(dpi)")
        }
    }

    func testCharactersDoNotEatDeadKeys() async {
        // US International has dead keys: ' is an accent, then a gives á. With flag 0x4 the keyboard's state is left alone.
        let klid = Array("00020409".utf16) + [0]
        guard let layout = klid.withUnsafeBufferPointer({ ptb_input_load_layout($0.baseAddress) }) else {
            throw XCTSkip("US International is not installed")
        }
        let none = [UInt8](repeating: 0, count: 256)
        XCTAssertNil(WinPlazaInput.characters(virtualKey: 0xDE /* VK_OEM_7 */, scanCode: 0x28, extended: false, state: none, layout: layout),
                     "a dead key gives nil")
        XCTAssertEqual(WinPlazaInput.characters(virtualKey: 0x41, scanCode: 0x1E, extended: false, state: none, layout: layout), "a",
                       "the accent was not consumed by the call")
        // without the flag the dead key is taken and the next letter carries it (what TranslateMessage would have lost)
        XCTAssertNil(WinPlazaInput.characters(virtualKey: 0xDE, scanCode: 0x28, extended: false, state: none, layout: layout, flags: 0))
        XCTAssertEqual(WinPlazaInput.characters(virtualKey: 0x41, scanCode: 0x1E, extended: false, state: none, layout: layout, flags: 0), "\u{E1}")
    }

    func testCtrlIsLeftOutOfTheCharactersButAltGrStays() async {
        var state = [UInt8](repeating: 0, count: 256)
        state[0x11] = 0x80; state[0xA2] = 0x80
        let plain = WinPlazaInput.charactersState(state)
        XCTAssertEqual(plain[0x11], 0)
        XCTAssertEqual(plain[0xA2], 0)
        state[0x12] = 0x80; state[0xA5] = 0x80
        XCTAssertEqual(WinPlazaInput.charactersState(state)[0xA2], 0x80, "AltGr keeps its Ctrl")
    }

    func testPhysicalKeysDoNotFollowTheLayout() async {
        // The same scan code is the same key whatever it types: the position of A on AZERTY (Q) is still the Mac's A.
        XCTAssertEqual(WinPlazaInput.macKeyCode(scanCode: 0x1E, extended: false, virtualKey: 0x51 /* VK_Q on AZERTY */), PlazaKeyCode.a)
    }
}
#endif
