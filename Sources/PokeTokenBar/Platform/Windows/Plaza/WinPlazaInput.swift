#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// The plaza's keyboard and mouse on Windows (D7): Win32 messages turned into the shared input types the Mac's
/// `PlazaSKScene` and `PlazaPanelHostView` produce from `NSEvent`s. Keys are identified by POSITION (the scan code), as the
/// Mac's `kVK_*` numbers are, so walking works on every layout and with the Korean IME on; characters come only from
/// `ToUnicodeEx` for the three keys the scene matches by text ("-", "=", "+"). Pure functions here; the stateful part is
/// `WinPlazaInputRouter`.
enum WinPlazaInput {
    // MARK: key identity

    /// One Windows key position and the macOS virtual key number at the same position (ANSI), for every key with a Mac
    /// counterpart: letters, digits, punctuation, Space/Enter/Esc/Tab/Backspace, the arrows and the keypad. `extended` is the
    /// `lParam` bit 24 (right-hand and navigation-cluster keys).
    private static let keyTable: [(scan: UInt32, extended: Bool, mac: UInt16)] = [
        (0x01, false, 53),
        (0x02, false, 18), (0x03, false, 19), (0x04, false, 20), (0x05, false, 21), (0x06, false, 23),
        (0x07, false, 22), (0x08, false, 26), (0x09, false, 28), (0x0A, false, 25), (0x0B, false, 29),
        (0x0C, false, 27), (0x0D, false, 24), (0x0E, false, 51), (0x0F, false, 48),
        (0x10, false, 12), (0x11, false, 13), (0x12, false, 14), (0x13, false, 15), (0x14, false, 17),
        (0x15, false, 16), (0x16, false, 32), (0x17, false, 34), (0x18, false, 31), (0x19, false, 35),
        (0x1A, false, 33), (0x1B, false, 30), (0x1C, false, 36),
        (0x1E, false, 0), (0x1F, false, 1), (0x20, false, 2), (0x21, false, 3), (0x22, false, 5),
        (0x23, false, 4), (0x24, false, 38), (0x25, false, 40), (0x26, false, 37), (0x27, false, 41),
        (0x28, false, 39), (0x29, false, 50), (0x2B, false, 42),
        (0x2C, false, 6), (0x2D, false, 7), (0x2E, false, 8), (0x2F, false, 9), (0x30, false, 11),
        (0x31, false, 45), (0x32, false, 46), (0x33, false, 43), (0x34, false, 47), (0x35, false, 44),
        (0x39, false, 49), (0x56, false, 10),
        // keypad: * - + . 0-9 (NumLock on; with it off the arrows below take 8/4/6/2), / and Enter (extended)
        (0x37, false, 67), (0x4A, false, 78), (0x4E, false, 69), (0x53, false, 65),
        (0x52, false, 82), (0x4F, false, 83), (0x50, false, 84), (0x51, false, 85), (0x4B, false, 86),
        (0x4C, false, 87), (0x4D, false, 88), (0x47, false, 89), (0x48, false, 91), (0x49, false, 92),
        (0x35, true, 75), (0x1C, true, 76),
        // the dedicated arrows (extended)
        (0x4B, true, 123), (0x4D, true, 124), (0x50, true, 125), (0x48, true, 126),
    ]

    private static func slot(_ scan: UInt32, _ extended: Bool) -> UInt32 { scan | (extended ? 0x100 : 0) }
    private static let macBySlot: [UInt32: UInt16] = Dictionary(uniqueKeysWithValues: keyTable.map { (slot($0.scan, $0.extended), $0.mac) })
    private static let slotByMac: [UInt16: UInt32] = Dictionary(uniqueKeysWithValues: keyTable.map { ($0.mac, slot($0.scan, $0.extended)) })

    /// The Mac key number at the position of this Windows key; nil for keys the Mac scene cannot name (modifiers, F-keys,
    /// the navigation cluster). A non-extended arrow virtual key is the keypad's 8/4/6/2 with NumLock off: the arrow.
    static func macKeyCode(scanCode: UInt32, extended: Bool, virtualKey: UInt32? = nil) -> UInt16? {
        if !extended, let vk = virtualKey {
            switch vk {
            case 0x25: return PlazaKeyCode.left
            case 0x26: return PlazaKeyCode.up
            case 0x27: return PlazaKeyCode.right
            case 0x28: return PlazaKeyCode.down
            default: break
            }
        }
        return macBySlot[slot(scanCode & 0xFF, extended)]
    }

    /// The key position for a Mac key number (the selftest sends keys by position; the table's inverse).
    static func scanCode(forMacKeyCode code: UInt16) -> (scan: UInt32, extended: Bool)? {
        slotByMac[code].map { ($0 & 0xFF, $0 & 0x100 != 0) }
    }

    /// `lParam` of a key message (`WM_KEYDOWN`...): bits 16-23 scan code, 24 extended, 30 previous state (down already =
    /// auto-repeat, what AppKit's `isARepeat` is), 31 transition (1 = release).
    struct KeyBits: Equatable {
        let scanCode: UInt32
        let extended: Bool
        let isRepeat: Bool
        let isRelease: Bool

        init(lParam: LPARAM) {
            let bits = UInt32(truncatingIfNeeded: lParam)
            scanCode = (bits >> 16) & 0xFF
            extended = bits & (1 << 24) != 0
            isRepeat = bits & (1 << 30) != 0
            isRelease = bits & (1 << 31) != 0
        }
    }

    /// The shared event for a key message, or nil for a key without a Mac counterpart.
    static func event(bits: KeyBits, virtualKey: UInt32, modifiers: PlazaModifiers, characters: String?) -> PlazaKeyEvent? {
        guard let code = macKeyCode(scanCode: bits.scanCode, extended: bits.extended, virtualKey: virtualKey) else { return nil }
        return PlazaKeyEvent(keyCode: code, characters: characters, isRepeat: bits.isRepeat, modifiers: modifiers)
    }

    /// `WM_KEYDOWN` / `WM_SYSKEYDOWN`'s `wParam` (the virtual key, or VK_PROCESSKEY) and `lParam`. The position decides the
    /// key, so a key the IME took (`VK_PROCESSKEY`) is still the same key.
    @MainActor static func keyEvent(wParam: WPARAM, lParam: LPARAM) -> PlazaKeyEvent? {
        let bits = KeyBits(lParam: lParam)
        let vk = UInt32(truncatingIfNeeded: wParam)
        guard macKeyCode(scanCode: bits.scanCode, extended: bits.extended, virtualKey: vk) != nil else { return nil }
        var state = [UInt8](repeating: 0, count: 256)
        let text: String? = ptb_input_keyboard_state(&state) == 1
            ? characters(virtualKey: vk, scanCode: bits.scanCode, extended: bits.extended, state: charactersState(state)) : nil
        return event(bits: bits, virtualKey: vk, modifiers: currentModifiers(), characters: text)
    }

    // MARK: characters

    /// What the key types (UTF-16 from `ToUnicodeEx`), with flag 0x4 so the call does not take the keyboard's dead-key state
    /// away from the `TranslateMessage` that follows. A dead key and a key without text give nil.
    static func characters(virtualKey: UInt32, scanCode: UInt32, extended: Bool, state: [UInt8],
                           layout: UnsafeMutableRawPointer? = nil, flags: UInt32 = 0x4) -> String? {
        guard state.count == 256 else { return nil }
        var out = [UInt16](repeating: 0, count: 8)
        let count = state.withUnsafeBufferPointer { keys in
            ptb_input_characters(virtualKey, scanCode | (extended ? 0xE000 : 0), layout, keys.baseAddress, flags, &out, Int32(out.count))
        }
        return count > 0 ? String(decoding: out.prefix(Int(count)), as: UTF16.self) : nil
    }

    /// Ctrl stands for ⌘ here, and ⌘ does not change what a Mac key types, so Ctrl is taken out of the state the characters
    /// come from (Ctrl+- still zooms); AltGr (Ctrl+RightAlt) stays, it is how that layout types its characters.
    static func charactersState(_ state: [UInt8]) -> [UInt8] {
        guard state.count == 256, !isAltGr({ state[Int($0)] & 0x80 != 0 }) else { return state }
        var copy = state
        for vk in [0x11, 0xA2, 0xA3] { copy[vk] = 0 }
        return copy
    }

    // MARK: modifiers

    private static let vkShift: Int32 = 0x10, vkControl: Int32 = 0x11, vkMenu: Int32 = 0x12
    private static let vkLeftControl: Int32 = 0xA2, vkRightControl: Int32 = 0xA3, vkLeftMenu: Int32 = 0xA4, vkRightMenu: Int32 = 0xA5

    /// AltGr on a layout that has it arrives as a left Ctrl plus the right Alt. That pair is a character key, not the
    /// Ctrl chord (Ctrl+W must not close the plaza while someone types an AltGr character).
    static func isAltGr(_ isDown: (Int32) -> Bool) -> Bool {
        isDown(vkRightMenu) && isDown(vkLeftControl) && !isDown(vkRightControl) && !isDown(vkLeftMenu)
    }

    /// Shift → .shift; Ctrl → .command + .control (a Ctrl chord blocks emotes and walking and Ctrl+W closes, as ⌘ does);
    /// Alt → .option; AltGr → .option only; the Windows key → nothing.
    static func modifiers(isDown: (Int32) -> Bool) -> PlazaModifiers {
        var m: PlazaModifiers = []
        if isDown(vkShift) { m.insert(.shift) }
        if isDown(vkControl), !isAltGr(isDown) { m.formUnion([.command, .control]) }
        if isDown(vkMenu) { m.insert(.option) }
        return m
    }

    /// The keyboard as the thread has processed it (`GetKeyState`): the scene polls it every frame.
    static func currentModifiers() -> PlazaModifiers {
        modifiers { GetKeyState($0) < 0 }
    }

    // MARK: mouse and wheel

    /// The Mac host's line step: an AppKit line is 10 points (`PlazaPanelHostView.lineScrollStep`).
    static let pointsPerLine: CGFloat = 10

    /// A client-area pixel as window points (origin top-left): the renderer's own `dpi / 96`.
    static func point(clientX: Int32, clientY: Int32, dpi: UInt32) -> CGPoint {
        let scale = CGFloat(dpi) / 96
        return CGPoint(x: CGFloat(clientX) / scale, y: CGFloat(clientY) / scale)
    }

    /// `WM_MOUSEWHEEL` (vertical) / `WM_MOUSEHWHEEL`: a notch (120) is `linesPerNotch` lines of 10 points, any fraction of it
    /// proportionally (a precision touchpad's small deltas add up to the same distance). Positive dy = wheel away from the
    /// user, as AppKit's `scrollingDeltaY`; Windows' horizontal wheel is positive to the right, so dx has its sign flipped.
    static func wheel(delta: Int32, horizontal: Bool, linesPerNotch: Int) -> (dx: CGFloat, dy: CGFloat) {
        let distance = CGFloat(delta) * CGFloat(linesPerNotch) * pointsPerLine / 120
        return horizontal ? (-distance, 0) : (0, distance)
    }
}

/// The stateful half of D7 for one plaza window: handles the window's keyboard, mouse and focus messages, keeps the set of
/// held keys so every one gets its key-up when the window loses the keyboard (focus loss, minimise, lock, a menu or move
/// loop), captures the mouse while a button is down, and tracks the pointer's leaving only while a drawing that tracks the
/// mouse is under it. No timers: it runs only inside the messages. Main thread only.
@MainActor final class WinPlazaInputRouter {
    struct Counts: Equatable {
        var keyDowns = 0, keyUps = 0, repeats = 0, releases = 0, mouseEvents = 0, wheelEvents = 0, ignoredPinch = 0
    }

    /// Where a pointer position that cannot hit anything goes (the cancelled press of a lost capture).
    static let nowhere = CGPoint(x: -1_000_000, y: -1_000_000)

    private let hwnd: HWND
    private let stage: () -> WinPlazaStage?
    private let scale: () -> CGFloat
    private(set) var held: Set<UInt16> = []
    private(set) var counts = Counts()
    private var pressed = false, hovered = false, leaveRequested = false
    private var lastPoint = CGPoint.zero

    /// The selftest turns this off while it counts keys, so a key like Esc or Space changes nothing in the scene.
    var forwardToStage = true
    /// Task 10: the HUD's panels. The scene takes no mouse (as on the Mac), so what no panel takes goes nowhere.
    var onMouse: ((PlazaMouseEvent) -> Bool)?
    /// Task 10: whether a drawing that tracks the mouse is under this window point (hover costs nothing otherwise).
    var tracksMouse: ((CGPoint) -> Bool)?
    /// Task 11: called when the window gets the keyboard or the input language changes, to keep the scene's IME context off.
    var reassertIME: (() -> Void)?
    var keyObserver: ((PlazaKeyEvent) -> Void)?
    var keyUpObserver: ((UInt16) -> Void)?
    var mouseObserver: ((PlazaMouseEvent) -> Void)?

    init(hwnd: HWND, stage: @escaping () -> WinPlazaStage?, scale: @escaping () -> CGFloat) {
        self.hwnd = hwnd
        self.stage = stage
        self.scale = scale
    }

    /// nil: DefWindowProc (system keys, unmapped keys, everything this does not own).
    func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case 0x0100, 0x0104: return key(down: true, system: message == 0x0104, wParam, lParam)   // WM_KEYDOWN, WM_SYSKEYDOWN
        case 0x0101, 0x0105: return key(down: false, system: message == 0x0105, wParam, lParam)  // WM_KEYUP, WM_SYSKEYUP
        case 0x0102, 0x0103, 0x0107: return 0   // WM_CHAR, WM_DEADCHAR, WM_SYSDEADCHAR: the scene reads keys, not text
        case 0x0106: return wParam == 0x20 ? nil : 0   // WM_SYSCHAR: swallowed (no beep); Alt+Space opens the system menu
        case 0x0112:   // WM_SYSCOMMAND: a lone Alt or F10 (SC_KEYMENU) must not put the window in menu mode
            guard wParam & 0xFFF0 == 0xF100 else { return nil }
            return lParam == 0x20 ? nil : 0
        case 0x0007, 0x0051:   // WM_SETFOCUS, WM_INPUTLANGCHANGE
            reassertIME?()
            return nil
        case 0x0008, 0x0211, 0x001F:   // WM_KILLFOCUS, WM_ENTERMENULOOP, WM_CANCELMODE
            releaseAll()
            return nil
        case 0x0215:   // WM_CAPTURECHANGED: someone else took the mouse while a button was down
            if pressed {
                pressed = false
                deliver(.up, Self.nowhere)
            }
            return nil
        case 0x0201: return leftDown(lParam)
        case 0x0202: return leftUp(lParam)
        case 0x0200: return move(lParam)
        case 0x02A3: return leave()
        case 0x0204, 0x0205, 0x0207, 0x0208: return 0   // right and middle buttons: the Mac host takes none
        case 0x020A: return wheel(horizontal: false, wParam, lParam)
        case 0x020E: return wheel(horizontal: true, wParam, lParam)
        default: return nil
        }
    }

    /// A key-up for every key still held: the window lost the keyboard (or is about to run a loop that would keep the key-up).
    func releaseAll() {
        guard !held.isEmpty else { return }
        let keys = held.sorted()
        held.removeAll()
        for code in keys {
            counts.releases += 1
            keyUpObserver?(code)
            if forwardToStage { stage()?.key(up: code) }
        }
    }

    // MARK: keys

    private func key(down: Bool, system: Bool, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        let vk = UInt32(truncatingIfNeeded: wParam)
        if system, vk == 0x73 || vk == 0x20 { return nil }   // Alt+F4 closes, Alt+Space opens the system menu
        if down {
            guard let event = WinPlazaInput.keyEvent(wParam: wParam, lParam: lParam) else { return system ? 0 : nil }
            if event.isRepeat { counts.repeats += 1 } else { held.insert(event.keyCode) }
            counts.keyDowns += 1
            keyObserver?(event)
            if forwardToStage { stage()?.key(down: event) }
            return 0
        }
        let bits = WinPlazaInput.KeyBits(lParam: lParam)
        guard let code = WinPlazaInput.macKeyCode(scanCode: bits.scanCode, extended: bits.extended, virtualKey: vk) else {
            return system ? 0 : nil
        }
        held.remove(code)
        counts.keyUps += 1
        keyUpObserver?(code)
        if forwardToStage { stage()?.key(up: code) }
        return 0
    }

    // MARK: mouse

    private func point(_ lParam: LPARAM) -> CGPoint {
        let s = scale()
        let p = CGPoint(x: CGFloat(Int16(truncatingIfNeeded: lParam)) / s, y: CGFloat(Int16(truncatingIfNeeded: lParam >> 16)) / s)
        lastPoint = p
        return p
    }

    private func deliver(_ kind: PlazaMouseEvent.Kind, _ location: CGPoint) {
        let event = PlazaMouseEvent(kind: kind, location: location)
        counts.mouseEvents += 1
        mouseObserver?(event)
        _ = onMouse?(event)
    }

    private func leftDown(_ lParam: LPARAM) -> LRESULT? {
        if GetFocus() != hwnd { _ = SetFocus(hwnd) }   // a click gives the scene the keyboard (the window never takes it by itself)
        pressed = true
        _ = SetCapture(hwnd)   // the release still arrives when the pointer is dragged out of the window
        deliver(.down, point(lParam))
        return 0
    }

    private func leftUp(_ lParam: LPARAM) -> LRESULT? {
        let was = pressed
        deliver(.up, point(lParam))
        if was {
            pressed = false
            _ = ReleaseCapture()
        }
        return 0
    }

    private func move(_ lParam: LPARAM) -> LRESULT? {
        let p = point(lParam)
        if pressed || tracksMouse?(p) == true {
            if !leaveRequested { leaveRequested = ptb_window_track_leave(UnsafeMutableRawPointer(hwnd)) == 1 }
            hovered = true
            deliver(.moved, p)
        } else if hovered {
            hovered = false
            deliver(.exited, p)
        }
        return 0
    }

    private func leave() -> LRESULT? {
        leaveRequested = false
        if hovered {
            hovered = false
            deliver(.exited, lastPoint)
        }
        return 0
    }

    private func wheel(horizontal: Bool, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        if (wParam & 0xFFFF) & 0x0008 != 0 {   // MK_CONTROL: a precision touchpad's pinch (the Mac host has no zoom gesture)
            counts.ignoredPinch += 1
            return 0
        }
        let delta = Int32(Int16(truncatingIfNeeded: wParam >> 16))
        var at = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        _ = ScreenToClient(hwnd, &at)   // the wheel's position is in screen coordinates
        let s = scale()
        let lines = Int(ptb_input_wheel_lines(horizontal ? 1 : 0))
        let d = WinPlazaInput.wheel(delta: delta, horizontal: horizontal, linesPerNotch: lines)
        counts.wheelEvents += 1
        deliver(.scroll(dx: d.dx, dy: d.dy), CGPoint(x: CGFloat(at.x) / s, y: CGFloat(at.y) / s))
        return 0
    }
}
#endif
