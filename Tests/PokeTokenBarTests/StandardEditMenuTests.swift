import XCTest
import AppKit
@testable import PokeTokenBar

@MainActor
final class StandardEditMenuTests: XCTestCase {
    /// SwiftUI's empty scene leaves a main menu with only "View" in it.
    private func swiftUIEmptySceneMenu() -> NSMenu {
        let menu = NSMenu(title: "Main")
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        view.submenu = NSMenu(title: "View")
        menu.addItem(view)
        return menu
    }

    private func item(_ menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    func testEditShortcutsReachTheFirstResponder() throws {
        let menu = swiftUIEmptySceneMenu()
        XCTAssertNil(item(menu, key: "v", modifiers: .command), "the fixture must lack paste, like the app did")
        StandardEditMenu.install(in: menu)
        let expected: [(String, NSEvent.ModifierFlags, String)] = [
            ("v", .command, "paste:"), ("c", .command, "copy:"), ("x", .command, "cut:"),
            ("a", .command, "selectAll:"), ("z", .command, "undo:"), ("z", [.command, .shift], "redo:"),
            // AppKit added no Emoji & Symbols item, so Control+Command+Space opened nothing in any field.
            (" ", [.control, .command], "orderFrontCharacterPalette:"),
        ]
        for (key, modifiers, action) in expected {
            let found = try XCTUnwrap(item(menu, key: key, modifiers: modifiers), "\(key) \(modifiers)")
            XCTAssertEqual(found.action.map(NSStringFromSelector), action)
            XCTAssertNil(found.target, "\(action) must go to the first responder")
        }
        XCTAssertEqual(menu.items.map(\.title), ["View", "Edit"], "the existing menu is kept")
    }

    func testInstallingTwiceAddsOneMenu() {
        let menu = swiftUIEmptySceneMenu()
        StandardEditMenu.install(in: menu)
        StandardEditMenu.install(in: menu)
        XCTAssertEqual(menu.items.filter { $0.submenu?.title == StandardEditMenu.title }.count, 1)
    }

    func testTheAppInstallsItAtLaunch() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/PokeTokenBarApp.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let body = source[launch.upperBound...].prefix(2000)
        XCTAssertTrue(body.contains("StandardEditMenu.install()"))
    }
}
