import Foundation

/// The modifier keys the plaza reads. Exactly the four the scene checks; AppKit's `.numericPad`, `.function` and
/// `.capsLock` are dropped at the Mac edge (`MacPlazaInput.swift`), which no scene check ever looked at.
struct PlazaModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let shift = PlazaModifiers(rawValue: 1 << 0)
    static let control = PlazaModifiers(rawValue: 1 << 1)
    static let option = PlazaModifiers(rawValue: 1 << 2)
    static let command = PlazaModifiers(rawValue: 1 << 3)
}

/// One key press as the scene sees it. `keyCode` is the macOS virtual key number (`PlazaKeyCode`); other OSes map
/// their keys to it.
struct PlazaKeyEvent: Equatable, Sendable {
    let keyCode: UInt16
    let characters: String?
    let isRepeat: Bool
    let modifiers: PlazaModifiers
}

/// The macOS virtual key numbers the scene names.
enum PlazaKeyCode {
    static let a: UInt16 = 0
    static let d: UInt16 = 2
    static let f: UInt16 = 3
    static let g: UInt16 = 5
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let w: UInt16 = 13
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let p: UInt16 = 35
    static let returnKey: UInt16 = 36
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}
