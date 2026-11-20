import Foundation

/// Local editing state of the difficulty sliders (stage 7 Task 15, G9): the shared twin of the Mac's `DifficultyDraft`
/// (`UI/DifficultySettingsSection.swift`, which is SwiftUI and upstream-owned). The body is held to the Mac's by
/// `twins.txt` (a rename only) and `PopoverDifficultyDraftTwinTests+Mac` drives both over the same inputs. Closing Settings
/// discards a draft without touching the store; `save(to:)` is the only thing that writes (the store rescales the banked
/// growth progress itself, `CompanionStore.setGrowthDifficulty`).
struct PopoverDifficultyDraft: Equatable {
    var growth: Double
    var shop: Double

    @MainActor init(companion: CompanionStore) {
        growth = companion.growthDifficulty
        shop = companion.shopDifficulty
    }

    @MainActor func differs(from companion: CompanionStore) -> Bool {
        growth != companion.growthDifficulty || shop != companion.shopDifficulty
    }

    @MainActor mutating func save(to companion: CompanionStore) {
        companion.setGrowthDifficulty(growth)
        companion.setShopDifficulty(shop)
        self = PopoverDifficultyDraft(companion: companion)
    }
}

/// The Mac's slider is continuous over 0...1 (`PokemonBalance.difficulty(atPosition:)`, a log scale that snaps to the
/// default); a Windows trackbar has integer positions. `resolution` positions span the same track, so a trackbar position
/// maps to the Mac's slider position `position / resolution` and from there to the same value the Mac would set.
enum PopoverDifficultySlider {
    static let resolution = 200
    static let range = 0...resolution
    /// A page key moves a tenth of the track (an arrow key one position).
    static let page = resolution / 10

    /// The trackbar position that shows `value` (the Mac's `difficultyPosition`).
    static func position(of value: Double) -> Int {
        let p = (PokemonBalance.difficultyPosition(value) * Double(resolution)).rounded()
        return min(max(Int(p), range.lowerBound), range.upperBound)
    }

    /// The value a trackbar position sets (the Mac's `difficulty(atPosition:)`).
    static func value(atPosition position: Int) -> Double {
        PokemonBalance.difficulty(atPosition: Double(position) / Double(resolution))
    }
}
