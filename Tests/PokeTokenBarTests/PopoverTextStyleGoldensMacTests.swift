import AppKit
import XCTest
@testable import PokeTokenBar

/// Measures the Mac's text styles and label opacities (no window: fonts and colours only) into
/// `Tests/PopoverParity/mac-text-styles.json`, which the Windows kit's font table is held to on both systems
/// (`PopoverTextStyleTests`). Every Mac run re-measures and fails when a macOS update changes a value; set
/// `PTB_WRITE_POPOVER_GOLDENS=1` to write the file again.
final class PopoverTextStyleGoldensMacTests: XCTestCase {
    /// The SwiftUI text styles the popover uses, as AppKit names them (SwiftUI's macOS styles are AppKit's sizes).
    private static let styles: [(PopoverTextStyle, NSFont.TextStyle?)] = [
        (.body, .body), (.callout, .callout), (.caption, .caption1), (.caption2, .caption2), (.headline, .headline), (.title3, .title3),
        (.largeBold, nil),
    ]

    static func weight(ofFontNamed name: String) -> Int? {
        for (suffix, weight) in [("Semibold", 600), ("Medium", 500), ("Regular", 400), ("Bold", 700)] where name.hasSuffix(suffix) {
            return weight
        }
        return nil
    }

    static func measure() throws -> MacTextStyleGolden {
        var out: [MacTextStyleGolden.Style] = []
        for (style, appKit) in styles {
            let font = appKit.map { NSFont.preferredFont(forTextStyle: $0) } ?? NSFont.systemFont(ofSize: 28, weight: .bold)
            let weight = try XCTUnwrap(weight(ofFontNamed: font.fontName), "unknown weight in \(font.fontName)")
            out.append(.init(name: style.rawValue, size: Double(font.pointSize), weight: weight, font: font.fontName))
        }
        var labels: [String: Double] = [:]
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for (name, color) in [("primary", NSColor.labelColor), ("secondary", NSColor.secondaryLabelColor),
                                  ("tertiary", NSColor.tertiaryLabelColor), ("separator", NSColor.separatorColor)] {
                let srgb = color.usingColorSpace(.sRGB)!
                labels[name] = (Double(srgb.alphaComponent) * 10000).rounded() / 10000
            }
        }
        return MacTextStyleGolden(measured: "NSFont.preferredFont(forTextStyle:) (body, callout, caption1, caption2, headline, title3) and "
                                  + "NSFont.systemFont(ofSize: 28, weight: .bold); the weight from the font's name; label alphas of "
                                  + "NSColor in the aqua appearance (black at that alpha)",
                                  styles: out, labels: labels)
    }

    func testTheMacTextStylesAreTheGolden() throws {
        let measured = try Self.measure()
        if ProcessInfo.processInfo.environment["PTB_WRITE_POPOVER_GOLDENS"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (encoder.encode(measured) + Data("\n".utf8)).write(to: MacTextStyleGolden.url)
        }
        XCTAssertEqual(try MacTextStyleGolden.load(), measured,
                       "macOS changed a text style or label colour: write the golden again (PTB_WRITE_POPOVER_GOLDENS=1) and check the Windows table")
    }

    func testTheWeightIsReadFromTheName() {
        XCTAssertEqual(Self.weight(ofFontNamed: ".SFNS-Regular"), 400)
        XCTAssertEqual(Self.weight(ofFontNamed: ".SFNS-Medium"), 500)
        XCTAssertEqual(Self.weight(ofFontNamed: ".SFNS-Semibold"), 600)
        XCTAssertEqual(Self.weight(ofFontNamed: ".AppleSystemUIFontBold"), 700)
        XCTAssertNil(Self.weight(ofFontNamed: ".SFNS-Heavy"))
    }
}
