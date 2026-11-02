import AppKit

/// The SwiftUI empty scene builds a main menu with no Edit menu. The menu bar is never shown for this
/// accessory app, but Cmd+C/V/X/A/Z still reach text fields only through main menu key equivalents, so
/// without this menu no field in the app can copy or paste from the keyboard.
@MainActor
enum StandardEditMenu {
    static let title = "Edit"

    /// Adds the Edit menu once. The actions go to the first responder, so every text field gets them.
    static func install(in menu: NSMenu) {
        guard !menu.items.contains(where: { $0.submenu?.title == title }) else { return }
        let edit = NSMenu(title: title)
        for (name, action, key, modifiers) in items {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = edit
        menu.addItem(root)
    }

    static func install(in app: NSApplication = .shared) {
        if app.mainMenu == nil { app.mainMenu = NSMenu(title: "Main") }
        if let menu = app.mainMenu { install(in: menu) }
    }

    private static let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
        ("Undo", Selector(("undo:")), "z", .command),
        ("Redo", Selector(("redo:")), "z", [.command, .shift]),
        ("Cut", #selector(NSText.cut(_:)), "x", .command),
        ("Copy", #selector(NSText.copy(_:)), "c", .command),
        ("Paste", #selector(NSText.paste(_:)), "v", .command),
        ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
    ]
}
