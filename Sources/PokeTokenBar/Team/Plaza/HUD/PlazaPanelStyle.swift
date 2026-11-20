import Foundation

/// The overlay look, copied from the SwiftUI views the panels replace (`PlazaOverlayView`'s pills and `PlazaClock`,
/// before Track A Task 14): colours (sRGB, as SwiftUI's `Color(red:green:blue:)`), corner radii, stroke widths, paddings
/// and the margins of the old constraints.
enum PlazaPanelStyle {
    /// A rounded pill with one text in it. The stroke is centred on the pill's edge (SwiftUI `.stroke`).
    struct Pill: Sendable {
        let font: PlazaFont
        let text: PlazaColor
        let fill: PlazaColor
        let stroke: PlazaColor
        let lineWidth: CGFloat
        let cornerRadius: CGFloat
        /// Between the text and the pill's edge: `width` left and right, `height` above and below.
        let padding: CGSize
    }

    static let countdown = Pill(font: .plaza(.body), text: .white, fill: PlazaColor(hex: 0x1D4F55, alpha: 0.92),
                                stroke: PlazaColor(hex: 0xF2C14E), lineWidth: 2, cornerRadius: 8,
                                padding: CGSize(width: 14, height: 8))
    static let banner = Pill(font: .plaza(.body), text: .white, fill: PlazaColor(hex: 0x1D4F55, alpha: 0.92),
                             stroke: PlazaColor(hex: 0x5FB7BD), lineWidth: 2, cornerRadius: 8,
                             padding: CGSize(width: 14, height: 8))
    static let hint = Pill(font: .plaza(.body), text: PlazaColor(hex: 0xF8F8F0), fill: PlazaColor(hex: 0x1D4F5C, alpha: 0.9),
                           stroke: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5), lineWidth: 1.5, cornerRadius: 6,
                           padding: CGSize(width: 12, height: 6))
    static let clock = Pill(font: .plaza(.small), text: PlazaColor(hex: 0xF8F8F0), fill: PlazaColor(hex: 0x1D4F5C, alpha: 0.9),
                            stroke: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5), lineWidth: 1.5, cornerRadius: 6,
                            padding: CGSize(width: 8, height: 5))

    /// The pills stack under the window's top edge, centred, this far apart (the old `VStack(spacing: 8)` with
    /// `.padding(.top, PlazaRosterMetrics.margin)`).
    static let pillSpacing: CGFloat = 8
    static let pillsTop: CGFloat = PlazaRosterMetrics.margin
    /// The banner pill is this wide (`.frame(maxWidth: 360)` in a window that is always wider) and wraps inside it.
    static let bannerWidth: CGFloat = 360

    /// A button's content while the mouse is down on it (and still inside it). SwiftUI's `.buttonStyle(.plain)` dims a pressed
    /// label; its factor cannot be measured off screen. Matches SwiftUI .plain by eye — to be confirmed in a live window.
    static let pressedOpacity: CGFloat = 0.6

    /// Room kept around the pills in a panel image for the half of a stroke that falls outside: the most any pill needs
    /// (2 / 2), and a whole number of device pixels at 1x, 2x and 3x (the 1.5 strokes' 0.75 rounds up to it).
    static let strokeRoom: CGFloat = 1

    /// The clock sits on the minimap: trailing edges aligned, 6 points above it; the minimap is 16 points above the
    /// window's bottom edge and `PlazaRosterMetrics.margin` from its trailing edge (the old constraints).
    static let clockAboveMinimap: CGFloat = 6
    static let minimapBottom: CGFloat = 16
    /// The minimap's height as `PlazaMinimapView` lays it out: the map scaled to `PlazaMinimapModel.width`, rounded, and
    /// 4 points of padding above and below.
    @MainActor static func minimapHeight(worldSize: CGSize) -> CGFloat {
        (PlazaMinimapModel.width * worldSize.height / max(worldSize.width, 1)).rounded() + 2 * 4
    }

    /// `v` on the device-pixel grid, rounded to the nearest pixel the way SwiftUI places a centred view.
    static func pixel(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        (v * scale).rounded() / scale
    }

    /// `v` rounded up to whole device pixels (a text's size, as SwiftUI sizes a `Text`). A width within a thousandth of
    /// a pixel above a boundary is that boundary (CoreText's sums of fractional advances land just above it; SwiftUI does
    /// not add a pixel for them).
    static func pixelUp(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        (v * scale - 0.001).rounded(.up) / scale
    }
}
