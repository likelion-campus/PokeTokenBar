import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PokeTokenBar

/// Stage 7 Task 12: writes the activity parts as the Mac canvas draws them (sample data, offscreen, no window) to the folder in
/// `PTB_ACTIVITY_PNG_DIR`, for the PR images; without the variable it only checks the render is not blank. Mac only: CoreGraphics.
@MainActor
final class PopoverActivityImagesMac: XCTestCase {
    private func input(_ kind: String, language: AppLanguage = .en, firstWeekday: Int = 2) -> ActivityInput {
        var i = ActivityInput()
        i.language = language
        i.today = "2026-07-15"
        i.window = .month
        i.showsCost = true
        i.providerOrder = ["claude_code", "codex", "cursor"]
        i.streak = UsageStreak(days: 5, includesToday: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = firstWeekday
        cal.locale = Locale(identifier: firstWeekday == 1 ? "en_US" : "ko_KR")
        i.facts = .windows(regionLocale: cal.locale ?? .current, regionCalendar: cal)
        let f = LocalUsageReader.localDayFormatter()
        let end = f.date(from: i.today)!
        let all: [DailyUsage] = (0...120).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: end)!
            var tokens = (cal.isDateInWeekend(d) ? 40_000 : 600_000) + (offset * 7_919) % 90_000
            if offset % 11 == 5 { tokens = 0 }
            if offset == 6 { tokens = 9_500_000 }
            return DailyUsage(date: f.string(from: d), inputTokens: tokens / 2, outputTokens: tokens - tokens / 2, cacheCreationTokens: 0,
                              cacheReadTokens: 0, totalTokens: tokens, totalCost: Double(tokens) / 2_000_000)
        }
        let month = all.filter { $0.date.hasPrefix("2026-07") }
        func share(_ n: Int) -> [DailyUsage] {
            month.map { DailyUsage(date: $0.date, inputTokens: 0, outputTokens: $0.totalTokens * n / 10, cacheCreationTokens: 0, cacheReadTokens: 0,
                                   totalTokens: $0.totalTokens * n / 10, totalCost: 0) }
        }
        switch kind {
        case "three":
            i.series = month
            i.providers = [.init(id: "claude_code", name: "Claude Code", days: share(5), reportsCost: true),
                           .init(id: "codex", name: "Codex", days: share(3), reportsCost: true),
                           .init(id: "cursor", name: "Cursor", days: share(2), reportsCost: false)]
        case "quiet":
            i.series = [all.last!.self].map { DailyUsage(date: $0.date, inputTokens: 6000, outputTokens: 6345, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 12_345, totalCost: 0.01) }
            i.streak = UsageStreak(days: 3, includesToday: false)
        case "heat":
            i.series = month
            var ledger = UsageLedger()
            ledger.merge(all.filter { !$0.date.hasPrefix("2026-07") })
            i.history = ledger
            i.visualization = .recentHeatmap
        default:
            i.series = month
            i.providers = [.init(id: "claude_code", name: "Claude Code", days: month, reportsCost: true)]
        }
        i.heatmapSeries = kind == "quiet" ? i.series : month
        return i
    }

    private func write(_ drawing: PopoverDrawing, size: CGSize, to url: URL, scale: CGFloat) throws {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        var bytes = PopoverComposite.compose(drawing.drawing.layers, width: w, height: h, scale: scale)
        // over the popover's light background
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let keep = 255 - Int(bytes[i + 3])
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, Int(bytes[i + c]) + 242 * keep / 255)) }
            bytes[i + 3] = 255
        }
        var rgba = bytes
        for i in stride(from: 0, to: w * h * 4, by: 4) { rgba.swapAt(i, i + 2) }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testTheActivityPartsDrawOnTheMacCanvasAndWriteTheirImages() throws {
        let dir = ProcessInfo.processInfo.environment["PTB_ACTIVITY_PNG_DIR"].map { URL(fileURLWithPath: $0) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let graphics = PlatformPlaza.graphics
        let width = PopoverWindowMetrics.contentWidth
        let cases: [(String, String, AppLanguage, Int, String?)] = [
            ("bars-one", "one", .en, 2, nil), ("bars-three", "three", .en, 2, "2026-07-09"), ("bars-quiet", "quiet", .en, 2, nil),
            ("bars-three-ko", "three", .ko, 2, "2026-07-09"), ("heatmap-monday", "heat", .en, 2, nil), ("heatmap-sunday", "heat", .en, 1, nil),
            ("heatmap-ko", "heat", .ko, 1, nil),
        ]
        for (name, kind, language, first, hover) in cases {
            let made = ActivityPanelModel.make(input(kind, language: language, firstWeekday: first))
            let part: any PopoverPart
            switch made.content {
            case .bars(let m)?: part = TrendBarsPart(m, cardInfo: made.cardInfo)
            case .heatmap(let m)?: part = HeatmapPart(m, readout: made.heatReadout)
            case nil: return XCTFail("\(name): nothing to draw")
            }
            let size = part.size(width: width, scale: 2, text: graphics.text)
            if let hover, let bars = part as? TrendBarsPart {
                bars.pointerMoved(CGPoint(x: 0, y: 0))
                for x in stride(from: CGFloat(0), to: width, by: 1) {
                    for y in stride(from: CGFloat(10), to: size.height, by: 1) where bars.date(at: CGPoint(x: x, y: y), graphics: graphics) == hover {
                        bars.pointerMoved(CGPoint(x: x, y: y))
                        break
                    }
                    if bars.selectedDate != nil { break }
                }
                XCTAssertEqual(bars.selectedDate, hover)
                if let card = bars.card(scale: 2, graphics: graphics), let dir {
                    try write(PopoverDrawing(drawing: card.drawing), size: card.frame.size, to: dir.appendingPathComponent("card-\(name).png"), scale: 2)
                }
            }
            let drawing = part.render(scale: 2, graphics: graphics)
            XCTAssertFalse(drawing.drawing.layers.isEmpty, name)
            if let dir { try write(drawing, size: size, to: dir.appendingPathComponent("\(name).png"), scale: 2) }
        }
        if let dir { // the streak badge, both states
            for (name, includes) in [("streak-today", true), ("streak-pending", false)] {
                let part = StreakPart(StreakModel(days: 5, includesToday: includes, label: "5"))
                let size = part.size(width: 120, scale: 2, text: graphics.text)
                try write(part.render(scale: 2, graphics: graphics), size: size, to: dir.appendingPathComponent("\(name).png"), scale: 2)
            }
        }
    }
}
