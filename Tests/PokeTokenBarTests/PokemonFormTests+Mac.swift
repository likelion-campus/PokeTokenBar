import XCTest
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension PokemonFormTests {
    func testFormPickerKeepsSevenColumnsForUnownAndWidensNamedForms() {
        XCTAssertEqual(PokemonDetailView.formPickerColumns(formCount: 28), 7)
        XCTAssertEqual(PokemonDetailView.formPickerColumns(formCount: 18), 6)
        XCTAssertEqual(PokemonDetailView.formPickerColumns(formCount: 6), 4)
        XCTAssertEqual(PokemonDetailView.formPickerColumns(formCount: 2), 2)
    }
}
