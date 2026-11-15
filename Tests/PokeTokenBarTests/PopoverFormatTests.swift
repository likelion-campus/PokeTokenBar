import XCTest
@testable import PokeTokenBar

/// The shared twins of the Mac popover's formatting helpers (stage 7, D8), on both systems: fixed goldens (the Mac
/// equivalence over a corpus is `PopoverTwinEquivalenceTests+Mac`) and the colour table against `mac-colors.json`.
final class PopoverFormatTests: XCTestCase {
    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private static let seoul: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    func testLimitPercentTextInBothModes() {
        XCTAssertEqual(PopoverFormat.limitPercentText(79.96, mode: .used, l: L(.en)), "80%")
        XCTAssertEqual(PopoverFormat.limitPercentText(88.35, mode: .used, l: L(.ko)), "88.3%")
        XCTAssertEqual(PopoverFormat.limitPercentText(30, mode: .remaining, l: L(.en)), "70% left")
        XCTAssertEqual(PopoverFormat.limitPercentText(30, mode: .remaining, l: L(.ko)), "70% 남음")
        XCTAssertEqual(PopoverFormat.limitPercentText(30, mode: .remaining, l: L(.ja)), "残り70%")
        XCTAssertEqual(PopoverFormat.limitPercentText(120, mode: .remaining, l: L(.en)), "0% left", "never below zero")
    }

    /// The day stamp and the clock come from the Mac's own templates (`HHmm`, `EEEEdHHmm`) in the app language, 24 h,
    /// in the calendar's zone; Task 1 pinned the same template outputs on both systems.
    func testTheResetClockSuffixNearbyAndFar() {
        let reset = Self.date("2026-09-10T10:26:00Z")   // Thursday 19:26 in Seoul
        let sameDay = reset.addingTimeInterval(-2 * 3600)
        let threeDays = reset.addingTimeInterval(-3 * 86_400)
        for language in [AppLanguage.ko, .en, .ja] {
            XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: sameDay, language: language, calendar: Self.seoul), " (19:26)")
        }
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: threeDays, language: .en, calendar: Self.seoul), " (Thursday 10, 19:26)")
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: threeDays, language: .ko, calendar: Self.seoul), " (10일 목요일 19:26)")
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: threeDays, language: .ja, calendar: Self.seoul), " (10日木曜日 19:26)")
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: reset.addingTimeInterval(60), language: .en, calendar: Self.seoul),
                       " (19:26)", "a reset a minute ago, today")
    }

    /// Across midnight the window decides: 6 h ahead still shows the clock only, a second more shows the day.
    func testTheResetClockWindowAcrossMidnight() {
        let reset = Self.date("2026-09-10T18:00:00Z")   // Friday 03:00 in Seoul
        let sixHours = reset.addingTimeInterval(-6 * 3600)
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: sixHours, language: .en, calendar: Self.seoul), " (03:00)")
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: sixHours.addingTimeInterval(-1), language: .en, calendar: Self.seoul),
                       " (Friday 11, 03:00)")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PopoverFormat.resetClockSuffix(reset, now: sixHours.addingTimeInterval(-1), language: .en, calendar: utc),
                       " (18:00)", "the same instants in UTC are one day: the clock only, in that zone")
    }

    func testPaceHelpAndMarker() {
        let l = L(.en)
        XCTAssertNil(PopoverFormat.paceHelp(pace: nil, tier: .onPace, utilization: 50, mode: .used, l: l))
        XCTAssertEqual(PopoverFormat.paceHelp(pace: 0.05, tier: nil, utilization: 50, mode: .used, l: l), l.paceHint("5%"))
        XCTAssertEqual(PopoverFormat.paceHelp(pace: 0.4, tier: .over, utilization: 60, mode: .remaining, l: l),
                       l.paceTier(.over) + " · " + l.paceDelta(20)! + "\n" + l.paceHint("60%"), "the hint's number follows the mode")
        XCTAssertEqual(PopoverFormat.paceHelp(pace: 0.5, tier: .onPace, utilization: 50, mode: .used, l: l),
                       l.paceTier(.onPace) + "\n" + l.paceHint("50%"), "no delta at zero")
        XCTAssertEqual(PopoverFormat.markerFraction(pace: 0.25, mode: .used)!, 0.25, accuracy: 1e-12)
        XCTAssertEqual(PopoverFormat.markerFraction(pace: 0.25, mode: .remaining)!, 0.75, accuracy: 1e-12)
        XCTAssertNil(PopoverFormat.markerFraction(pace: nil, mode: .used))
        let now = Self.date("2026-09-10T10:00:00Z")
        XCTAssertEqual(PopoverFormat.paceFraction(reset: now.addingTimeInterval(3600), span: 5 * 3600, now: now)!, 0.8, accuracy: 1e-12)
        XCTAssertNil(PopoverFormat.paceFraction(reset: now.addingTimeInterval(6 * 3600), span: 5 * 3600, now: now), "outside the window")
        XCTAssertNil(PopoverFormat.paceFraction(reset: nil, span: 5 * 3600, now: now))
        XCTAssertNil(PopoverFormat.paceFraction(reset: now, span: nil, now: now))
    }

    func testTheProductNamesAndColourRoles() {
        XCTAssertEqual(["GrokBot", "GrokBuild", "Api", "Other", nil].map(PopoverFormat.grokProductName), ["Grok", "Grok Build", "API", "Other", ""])
        XCTAssertEqual(PaceTier.allCases.map(PopoverFormat.paceColor),
                       [.systemBlue, .systemTeal, .systemGreen, .systemYellow, .systemOrange, .systemRed])
        XCTAssertEqual(PaceTier.allCases.map(PopoverFormat.percentColor),
                       [.systemBlue, .systemTeal, .systemGreen, .primary, .systemOrange, .systemRed])
        let indicators: [ProviderStatusIndicator] = [.operational, .minor, .maintenance, .major, .critical, .unknown]
        XCTAssertEqual(indicators.map(PopoverFormat.statusColor),
                       [.systemGreen, .systemYellow, .systemYellow, .systemOrange, .systemRed, .systemGray])
    }

    func testTheForecastTimeIsTwentyFourHourInTheGivenZone() {
        let t = Self.date("2026-09-10T13:05:00Z")
        XCTAssertEqual(PopoverFormat.forecastTime(t, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "Asia/Seoul")!), "22:05")
        XCTAssertEqual(PopoverFormat.forecastTime(t, locale: Locale(identifier: "ko_KR"), timeZone: TimeZone(identifier: "UTC")!), "13:05")
    }

    // MARK: - Colours

    static let colorsURL = PopoverParity.directory.appendingPathComponent("mac-colors.json")

    /// The shared table Windows draws equals what the Mac measured (`PopoverGoldens+Mac` writes and re-checks the file).
    func testTheColourTableIsTheMacsMeasuredValues() throws {
        let data = try Data(contentsOf: Self.colorsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func hex(_ value: Any?) throws -> PopoverRGBA { try XCTUnwrap((value as? String).flatMap(PopoverRGBA.init(hex:)), "\(String(describing: value))") }
        var mismatches: [String] = []
        let named = try XCTUnwrap(json["named"] as? [String: [String: String]])
        for role in PopoverColorRole.named {
            let name = try XCTUnwrap(role.name)
            for appearance in PopoverAppearance.allCases {
                let measured = try hex(named[appearance.rawValue]?[name])
                if role.macValue(appearance) != measured { mismatches.append("\(name) \(appearance): table \(role.macValue(appearance)), measured \(measured)") }
            }
        }
        for (key, count, role) in [("palette", 16, { PopoverColorRole.palette($0) }), ("heatmap", 5, { PopoverColorRole.heatmap(level: $0) })] {
            let lists = try XCTUnwrap(json[key] as? [String: [String]])
            for appearance in PopoverAppearance.allCases {
                let values = try XCTUnwrap(lists[appearance.rawValue])
                XCTAssertEqual(values.count, count, key)
                for (i, value) in values.enumerated() where role(i).macValue(appearance) != (try hex(value)) {
                    mismatches.append("\(key)[\(i)] \(appearance): table \(role(i).macValue(appearance)), measured \(value)")
                }
            }
        }
        XCTAssertEqual(PopoverColorRole.paletteCount, 16)
        XCTAssertEqual(PopoverColorRole.palette(17).macValue(.light), PopoverColorRole.palette(1).macValue(.light), "the palette wraps")
        XCTAssertEqual(PopoverColorRole.heatmap(level: 5).macValue(.light).alpha, 0, "outside 0…4: clear")
        XCTAssertEqual(mismatches, [], "\n" + mismatches.joined(separator: "\n") + "\n" + Self.swiftTable(json))
    }

    /// The table as Swift, from the json, for pasting into `PopoverColorRole.swift` after a re-measure.
    static func swiftTable(_ json: [String: Any]) -> String {
        func pair(_ light: String?, _ dark: String?) -> String {
            "(0x\((light ?? "#00000000").dropFirst()), 0x\((dark ?? "#00000000").dropFirst()))"
        }
        let named = json["named"] as? [String: [String: String]] ?? [:]
        var out = "static let macNamed: [PopoverColorRole: (light: UInt32, dark: UInt32)] = [\n"
        for role in PopoverColorRole.named {
            let name = role.name!
            out += "    .\(name): \(pair(named["light"]?[name], named["dark"]?[name])),\n"
        }
        out += "]\n"
        for key in ["palette", "heatmap"] {
            let lists = json[key] as? [String: [String]] ?? [:]
            let light = lists["light"] ?? [], dark = lists["dark"] ?? []
            out += "static let mac\(key.prefix(1).uppercased() + key.dropFirst()): [(light: UInt32, dark: UInt32)] = [\n"
            for i in 0..<light.count { out += "    \(pair(light[i], i < dark.count ? dark[i] : nil)),\n" }
            out += "]\n"
        }
        return out
    }
}
