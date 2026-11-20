import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// The Mac popover's colours, measured (stage 7, D8, D15): `Tests/PopoverParity/mac-colors.json` holds what SwiftUI
/// draws for each `PopoverColorRole`, the trend palette, the heatmap greens, and the rarity and type colours (Task 9),
/// in the light and dark appearance, as sRGB at 8 bits a channel. Mac only: it resolves SwiftUI colours.
///
/// - `PTB_WRITE_POPOVER_COLORS=1 swift test --filter PopoverGoldens` rewrites the file.
/// - Otherwise the checker fails when this macOS draws a colour differently from the file (a macOS update): re-measure,
///   then paste the table `PopoverFormatTests` prints into `PopoverColorRole.swift`.
///
/// Nothing is drawn and no window opens: colours resolve inside `NSAppearance.performAsCurrentDrawingAppearance`.
@MainActor
final class PopoverGoldensTests: XCTestCase {
    private static func resolve(_ color: NSColor, _ appearance: PopoverAppearance) -> PopoverRGBA {
        var out = PopoverRGBA(rgba: 0)
        NSAppearance(named: appearance == .light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
            out = PopoverRGBA(rgba: byte(c.redComponent) << 24 | byte(c.greenComponent) << 16 | byte(c.blueComponent) << 8
                              | byte(c.alphaComponent))
        }
        return out
    }

    private static func resolve(_ color: Color, _ appearance: PopoverAppearance) -> PopoverRGBA {
        resolve(NSColor(color), appearance)
    }

    /// What SwiftUI draws for each named role. `accent` is the Mac's default accent (Multicolor: `systemBlue`), not this
    /// Mac's setting; `tertiary` is the `.tertiary` text style.
    static let namedColors: [(PopoverColorRole, NSColor)] = [
        (.systemBlue, NSColor(Color.blue)), (.systemTeal, NSColor(Color.teal)), (.systemGreen, NSColor(Color.green)),
        (.systemYellow, NSColor(Color.yellow)), (.systemOrange, NSColor(Color.orange)), (.systemRed, NSColor(Color.red)),
        (.systemGray, NSColor(Color.gray)), (.accent, .systemBlue), (.primary, NSColor(Color.primary)),
        (.secondary, NSColor(Color.secondary)), (.tertiary, .tertiaryLabelColor),
    ]

    private static func measured() -> [String: Any] {
        var named: [String: [String: String]] = [:], palette: [String: [String]] = [:], heatmap: [String: [String]] = [:]
        var rarity: [String: [String: String]] = [:], types: [String: [String: String]] = [:]
        for appearance in PopoverAppearance.allCases {
            let a = appearance.rawValue
            named[a] = Dictionary(uniqueKeysWithValues: namedColors.map { ($0.0.name!, resolve($0.1, appearance).description) })
            palette[a] = MonthDailyTrend.providerPalette.map { resolve($0, appearance).description }
            heatmap[a] = (0...4).map { resolve(ActivityHeatmapMetrics.fill(level: $0), appearance).description }
            rarity[a] = Dictionary(uniqueKeysWithValues: ([nil] + [Rarity.common, .uncommon, .rare, .legendary]).map {
                ($0?.rawValue ?? "none", resolve(rarityColor($0), appearance).description)
            })
            types[a] = Dictionary(uniqueKeysWithValues: PokemonType.allCases.map { ($0.rawValue, resolve($0.color, appearance).description) })
        }
        return ["note": "Measured by PopoverGoldens+Mac (PTB_WRITE_POPOVER_COLORS=1): sRGB #RRGGBBAA. accent = the default (Multicolor) accent.",
                "named": named, "palette": palette, "heatmap": heatmap, "rarity": rarity, "types": types]
    }

    func testTheMeasuredColoursAreTheFiles() async throws {
        let live = Self.measured()
        let url = PopoverFormatTests.colorsURL
        if ProcessInfo.processInfo.environment["PTB_WRITE_POPOVER_COLORS"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: live, options: [.prettyPrinted, .sortedKeys])
            try (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
            print("POPOVER-COLORS written to \(url.path)")
        }
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        XCTAssertEqual(file, live as NSDictionary,
                       "this macOS draws a popover colour differently from mac-colors.json: rerun with PTB_WRITE_POPOVER_COLORS=1 and update PopoverColorRole")
        if Self.resolve(NSColor.controlAccentColor, .light) != Self.resolve(NSColor.systemBlue, .light) {
            print("POPOVER-COLORS note: this Mac has a custom accent; the file records the default accent")
        }
    }

    /// The Mac's `PaceTier.color` and `percentColor` (SwiftUI colours) are the roles the twins name.
    func testThePaceTierColoursAreTheTwinsRoles() async {
        for tier in PaceTier.allCases {
            for appearance in PopoverAppearance.allCases {
                XCTAssertEqual(Self.resolve(tier.color, appearance), PopoverFormat.paceColor(tier).macValue(appearance), "\(tier) \(appearance)")
                XCTAssertEqual(Self.resolve(tier.percentColor, appearance), PopoverFormat.percentColor(tier).macValue(appearance),
                               "\(tier) \(appearance)")
            }
        }
    }

    /// `statusColor` names SwiftUI's `.green` … `.gray`; the twin's renames map them to these roles (twins.txt).
    func testTheStatusColourNamesAreTheTwinsRoles() async {
        let pairs: [(Color, PopoverColorRole)] = [(.green, .systemGreen), (.yellow, .systemYellow), (.orange, .systemOrange),
                                                  (.red, .systemRed), (.gray, .systemGray)]
        for (color, role) in pairs {
            for appearance in PopoverAppearance.allCases {
                XCTAssertEqual(Self.resolve(color, appearance), role.macValue(appearance), "\(role) \(appearance)")
            }
        }
    }
}
