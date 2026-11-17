import Foundation

/// The popover's colours as roles (stage 7, D8, D15). The Mac views name SwiftUI colours (`.green`, `.orange`,
/// `.secondary`, the accent) and two fixed palettes; the shared models name the same colours by role, and each platform
/// draws a role its own way. Windows draws the Mac's values below (light now, dark with Task 16), except `accent`, which
/// is the user's Windows accent (D15; the Mac's default accent is listed for reference).
///
/// `systemBlue` … `systemGray` are SwiftUI's `.blue` … `.gray`; `primary` and `secondary` are `.primary` and
/// `.secondary`; `tertiary` is the `.tertiary` text style (`tertiaryLabelColor`).
///
/// The values are measured on the Mac into `Tests/PopoverParity/mac-colors.json` by `PopoverGoldens+Mac` (an env-gated
/// writer and an always-on checker that fails when a macOS update changes one); `PopoverFormatTests` holds this table to
/// that file on both systems.
enum PopoverColorRole: Hashable, Sendable {
    case systemBlue, systemTeal, systemGreen, systemYellow, systemOrange, systemRed, systemGray
    case accent, primary, secondary, tertiary
    /// `MonthDailyTrend.providerPalette[index % paletteCount]`: the trend bars' colour per provider.
    case palette(Int)
    /// `ActivityHeatmapMetrics.fill(level:)`: the heatmap greens for levels 0…4; any other level is clear.
    case heatmap(level: Int)

    /// The named (non-palette) roles, in a fixed order.
    static let named: [PopoverColorRole] = [.systemBlue, .systemTeal, .systemGreen, .systemYellow, .systemOrange,
                                            .systemRed, .systemGray, .accent, .primary, .secondary, .tertiary]

    /// The key of a named role in `mac-colors.json`.
    var name: String? {
        switch self {
        case .systemBlue: return "systemBlue"
        case .systemTeal: return "systemTeal"
        case .systemGreen: return "systemGreen"
        case .systemYellow: return "systemYellow"
        case .systemOrange: return "systemOrange"
        case .systemRed: return "systemRed"
        case .systemGray: return "systemGray"
        case .accent: return "accent"
        case .primary: return "primary"
        case .secondary: return "secondary"
        case .tertiary: return "tertiary"
        case .palette, .heatmap: return nil
        }
    }
}

enum PopoverAppearance: String, CaseIterable, Sendable { case light, dark }

/// An sRGB colour, 8 bits a channel, as `0xRRGGBBAA` (the hex the json writes as `#RRGGBBAA`).
struct PopoverRGBA: Hashable, Sendable, CustomStringConvertible {
    var rgba: UInt32

    var red: Double { Double((rgba >> 24) & 0xFF) / 255 }
    var green: Double { Double((rgba >> 16) & 0xFF) / 255 }
    var blue: Double { Double((rgba >> 8) & 0xFF) / 255 }
    var alpha: Double { Double(rgba & 0xFF) / 255 }

    var description: String {
        let hex = String(rgba, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    init(rgba: UInt32) { self.rgba = rgba }

    /// `#RRGGBBAA`, or nil.
    init?(hex: String) {
        guard hex.count == 9, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        rgba = value
    }
}

extension PopoverColorRole {
    static let paletteCount = macPalette.count

    /// The Mac's value of this role in `appearance`.
    func macValue(_ appearance: PopoverAppearance) -> PopoverRGBA {
        let pair: (light: UInt32, dark: UInt32)
        switch self {
        case .palette(let index):
            let count = Self.macPalette.count
            pair = Self.macPalette[((index % count) + count) % count]
        case .heatmap(let level):
            pair = (0...4).contains(level) ? Self.macHeatmap[level] : (0, 0)
        default:
            pair = Self.macNamed[self] ?? (0, 0)
        }
        return PopoverRGBA(rgba: appearance == .light ? pair.light : pair.dark)
    }

    /// The value Windows draws: the Mac's, except the secondary and tertiary label colours (black or white at
    /// `PopoverLabelOpacity.windowsLight…` / `windowsDark…`, readable on the popover; see there for the reason). Where `windows` is false this is
    /// `macValue`.
    func displayValue(_ appearance: PopoverAppearance, windows: Bool) -> PopoverRGBA {
        let mac = macValue(appearance)
        guard windows else { return mac }
        let alpha: Double
        switch self {
        case .secondary: alpha = PopoverLabelOpacity.secondary(appearance, windows: true)
        case .tertiary: alpha = PopoverLabelOpacity.tertiary(appearance, windows: true)
        default: return mac
        }
        return PopoverRGBA(rgba: mac.rgba & 0xFFFF_FF00 | UInt32((alpha * 255).rounded()))
    }

    // Measured by PopoverGoldens+Mac on macOS 26 (sRGB, 8 bits a channel, 0xRRGGBBAA); PopoverFormatTests holds them to
    // mac-colors.json. The palette is fixed sRGB, so its light and dark values are the same.
    static let macNamed: [PopoverColorRole: (light: UInt32, dark: UInt32)] = [
        .systemBlue: (0x0088FFFF, 0x0091FFFF),
        .systemTeal: (0x00C3D0FF, 0x00D2E0FF),
        .systemGreen: (0x34C759FF, 0x30D158FF),
        .systemYellow: (0xFFCC00FF, 0xFFD600FF),
        .systemOrange: (0xFF8D28FF, 0xFF9230FF),
        .systemRed: (0xFF383CFF, 0xFF4245FF),
        .systemGray: (0x8E8E93FF, 0x98989DFF),
        .accent: (0x0088FFFF, 0x0091FFFF),
        .primary: (0x000000D8, 0xFFFFFFD8),
        .secondary: (0x0000007F, 0xFFFFFF8C),
        .tertiary: (0x00000042, 0xFFFFFF3F),
    ]

    static let macPalette: [(light: UInt32, dark: UInt32)] = [
        (0xD97857FF, 0xD97857FF),
        (0x5C9EF2FF, 0x5C9EF2FF),
        (0x73C785FF, 0x73C785FF),
        (0xC78CEBFF, 0xC78CEBFF),
        (0xF2C252FF, 0xF2C252FF),
        (0x59C7CCFF, 0x59C7CCFF),
        (0xED82ADFF, 0xED82ADFF),
        (0x9EA3B2FF, 0x9EA3B2FF),
        (0xE0CC99FF, 0xE0CC99FF),
        (0xB2D161FF, 0xB2D161FF),
        (0x996B4CFF, 0x996B4CFF),
        (0x4C998CFF, 0x4C998CFF),
        (0xCC5966FF, 0xCC5966FF),
        (0x667ACCFF, 0x667ACCFF),
        (0xF59438FF, 0xF59438FF),
        (0xC29461FF, 0xC29461FF),
    ]

    static let macHeatmap: [(light: UInt32, dark: UInt32)] = [
        (0xEBEDF0FF, 0x161B22FF),
        (0x9BE9A8FF, 0x0E4429FF),
        (0x40C463FF, 0x006D32FF),
        (0x30A14EFF, 0x26A641FF),
        (0x216E39FF, 0x39D353FF),
    ]
}
