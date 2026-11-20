import AppKit

extension PlazaModifiers {
    /// Keeps the four flags the scene reads; `.numericPad`, `.function`, `.capsLock` and the rest are dropped.
    init(_ flags: NSEvent.ModifierFlags) {
        var m: PlazaModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

extension PlazaKeyEvent {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, characters: event.characters, isRepeat: event.isARepeat,
                  modifiers: PlazaModifiers(event.modifierFlags))
    }
}

enum MacPlazaInput {
    /// The keyboard's modifier state right now (`NSEvent.modifierFlags`), as the scene polls it every frame.
    @MainActor static func currentModifiers() -> PlazaModifiers { PlazaModifiers(NSEvent.modifierFlags) }
}
