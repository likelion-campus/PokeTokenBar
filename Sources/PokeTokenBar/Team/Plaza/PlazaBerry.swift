import Foundation

/// 열매 다섯 (berry five): the plaza's third minigame. This file holds what the table draws and the numbers it follows; the rules and the
/// engine come in later files.
enum PlazaBerry {
    /// The four berries. `itemName` is the Pokémon item picture's name (fetched at runtime, never part of the repository); `color` is the
    /// dot a card shows while that picture is missing.
    enum Berry: Int, CaseIterable, Codable, Sendable {
        case oran, sitrus, pecha, cheri

        var itemName: String {
            switch self {
            case .oran: "oran-berry"
            case .sitrus: "sitrus-berry"
            case .pecha: "pecha-berry"
            case .cheri: "cheri-berry"
            }
        }

        var color: PlazaColor {
            switch self {
            case .oran: PlazaColor(hex: 0x3B7BD1)
            case .sitrus: PlazaColor(hex: 0xF2C14E)
            case .pecha: PlazaColor(hex: 0xF09AB8)
            case .cheri: PlazaColor(hex: 0xD2453B)
            }
        }
    }

    /// One face-up card: a berry and how many of it, 1...5.
    struct Card: Hashable, Sendable {
        var berry: Berry
        var count: Int
    }

    /// The bell's item picture.
    static let bellItem = "soothe-bell"

    /// How long a card takes from its deck onto its pile.
    static let flipAnimation: TimeInterval = 0.3

    /// Berry centres on a face as fractions of its width and height from the top-left (the mockup's dice layout).
    static let pips: [Int: [CGPoint]] = [
        1: [CGPoint(x: 0.5, y: 0.5)],
        2: [CGPoint(x: 0.30, y: 0.28), CGPoint(x: 0.70, y: 0.72)],
        3: [CGPoint(x: 0.28, y: 0.24), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.72, y: 0.76)],
        4: [CGPoint(x: 0.30, y: 0.27), CGPoint(x: 0.70, y: 0.27), CGPoint(x: 0.30, y: 0.73), CGPoint(x: 0.70, y: 0.73)],
        5: [CGPoint(x: 0.28, y: 0.24), CGPoint(x: 0.72, y: 0.24), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.28, y: 0.76), CGPoint(x: 0.72, y: 0.76)],
    ]
}
