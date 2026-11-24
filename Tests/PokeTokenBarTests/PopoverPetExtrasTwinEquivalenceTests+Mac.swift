import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Stage 7 Task 23: the floating pet's bubbles, hearts, prayers, hover text, agent motion and agent flow
/// (`Popover/FloatingPetExtras.swift`) against the Mac's own members in `UI/FloatingPetPanel.swift` and
/// `UI/SpriteLoader.swift`, over the same inputs. Text measurement: the Mac's `measureSpeechBubbleLayout` is passed in, so
/// the shared cuts must produce the Mac's strings exactly.
@MainActor
final class PopoverPetExtrasTwinEquivalenceTests: XCTestCase {
    private typealias C = FloatingPetController
    private var rng = SeededRNG(seed: 23)

    /// The Mac's measurement in the shared shape.
    private static let macMeasure: FloatingPetBubbles.Measure = { title, body in
        let m = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        return .init(size: m.size, bodyLineCount: m.bodyLineCount, unclampedTitleWidth: m.unclampedTitleWidth,
                     unclampedBodyWidth: m.unclampedBodyWidth, wouldTruncate: m.wouldTruncate)
    }

    private func macBubble(_ b: FloatingPetBubbles.Bubble) -> C.Bubble {
        switch b {
        case .limit(let a): .limit(a)
        case .agentWaiting(let label, let message, let others): .agentWaiting(label: label, message: message, others: others)
        case .agentDone(let label, let message): .agentDone(label: label, message: message)
        }
    }

    private func pick<T>(_ xs: [T]) -> T { xs[Int.random(in: 0..<xs.count, using: &rng)] }

    private let labels: [String?] = [nil, "api", "poketokenbar", "a very long project folder name", "日本語のプロジェクト", "한글 폴더 이름", "emoji 🦊🐶", "x"]
    private let messages: [String?] = [nil, "Needs your input", "Approve the plan before I continue with the migration of the database schema",
                                       "テストが完了しました。結果を確認してください。長いメッセージの場合は省略されます。", "빌드가 끝났어요", "ok", String(repeating: "W", count: 80)]

    private func summary() -> AgentActivitySummary {
        var s = AgentActivitySummary()
        if Bool.random(using: &rng) { s.done = .init(label: pick(labels), message: pick(messages)) }
        if Bool.random(using: &rng) { s.waiting = .init(label: pick(labels), message: pick(messages)); s.otherWaitingCount = Int.random(in: 0...7, using: &rng) }
        s.working = Bool.random(using: &rng)
        return s
    }

    private func alert(_ l: L) -> UsageStore.LimitAlert? {
        guard Bool.random(using: &rng) else { return nil }
        return UsageStore.LimitAlert(key: "k", window: pick([l.claudeWeekly, l.claudeFiveHour, "Codex weekly (GPT-5 high)"]),
                                     isCritical: Bool.random(using: &rng), utilization: Double.random(in: 80...100, using: &rng).rounded(),
                                     account: pick([nil, "Corp", "personal@example.invalid", "A really long Claude account title"]))
    }

    func testTheConstantsAreTheMacs() async {
        XCTAssertEqual(FloatingPetBubbles.bubbleHorizontalPadding, C.bubbleHorizontalPadding)
        XCTAssertEqual(FloatingPetBubbles.bubbleContentWidth, C.bubbleContentWidth)
        XCTAssertEqual(FloatingPetBubbles.bubbleBodyLineLimit, C.bubbleBodyLineLimit)
        XCTAssertEqual(FloatingPetBubbles.heartDuration, C.heartDuration)
        XCTAssertEqual(FloatingPetBubbles.eventPopDuration, C.eventPopDuration)
        XCTAssertEqual(FloatingPetAgentMotion.agentRunDuration, C.agentRunDuration)
        XCTAssertEqual(FloatingPetAgentMotion.agentRunCursorGap, C.agentRunCursorGap)
        XCTAssertEqual(FloatingPetAgentMotion.agentBobInterval, C.agentBobInterval)
        XCTAssertEqual(FloatingPetPrayerArt.lifetime, PrayerBurst.lifetime)
        XCTAssertEqual(FloatingPetPetting.requiredReversals, PettingDetector.requiredReversals)
        XCTAssertEqual(FloatingPetPetting.window, PettingDetector.window)
        XCTAssertEqual(FloatingPetHeartArt.rows, HeartBubbleArt.rows)
        XCTAssertEqual(FloatingPetHeartArt.pixel, HeartBubbleArt.pixel)
        XCTAssertEqual(FloatingPetHeartArt.height, HeartBubbleArt.height)
        XCTAssertEqual(FloatingPetHeartArt.tailOverlap, HeartBubbleArt.tailOverlap)
        for cell: Character in ["O", "W", "R", "D", "H", ".", "x"] {
            let mac = HeartBubbleArt.color(for: cell).map { NSColor($0).usingColorSpace(.sRGB)! }
            let shared = FloatingPetHeartArt.rgb(for: cell)
            XCTAssertEqual(mac == nil, shared == nil, "cell \(cell)")
            if let mac, let shared {
                XCTAssertEqual(Int((mac.redComponent * 255).rounded()), Int(shared.r), "cell \(cell) red")
                XCTAssertEqual(Int((mac.greenComponent * 255).rounded()), Int(shared.g), "cell \(cell) green")
                XCTAssertEqual(Int((mac.blueComponent * 255).rounded()), Int(shared.b), "cell \(cell) blue")
            }
        }
        // The run's curve: CoreAnimation's ease-in-ease-out control points.
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &p1)
        curve.getControlPoint(at: 2, values: &p2)
        XCTAssertEqual([p1[0], p1[1], p2[0], p2[1]], [0.42, 0, 0.58, 1])
        // The Mac sources this file rebuilds as values (their bodies are pinned in twins.txt; the numbers are read here too).
        let mac = try? String(contentsOf: Self.sourcesRoot.appendingPathComponent("UI/FloatingPetPanel.swift"), encoding: .utf8)
        XCTAssertTrue(mac?.contains(".scaleEffect(x: squashed ? \(FloatingPetAgentMotion.bobScaleX) : 1, y: squashed ? \(FloatingPetAgentMotion.bobScaleY) : 1, anchor: .bottom)") == true)
        XCTAssertTrue(mac?.contains("RoundedRectangle(cornerRadius: \(Int(FloatingPetBubbleChrome.cornerRadius)), style: .continuous)") == true)
        XCTAssertTrue(mac?.contains(".shadow(color: .black.opacity(\(FloatingPetBubbleChrome.shadowOpacity)), radius: \(Int(FloatingPetBubbleChrome.shadowRadius)), y: \(Int(FloatingPetBubbleChrome.shadowOffsetY)))") == true)
        XCTAssertTrue(mac?.contains("VStack(spacing: \(Int(FloatingPetBubbleChrome.spacingToSprite))) {") == true)
        XCTAssertTrue(mac?.contains("withAnimation(.easeOut(duration: \(Int(FloatingPetPrayerArt.riseDuration)))) { progress = 1 }") == true)
        for frame in FloatingPetPrayerArt.wobble {
            let angle = String(format: "%.1f", frame.angle), seconds = String(format: "%.2f", frame.duration)
            XCTAssertTrue(mac?.contains("LinearKeyframe(\(angle), duration: \(seconds))") == true, "wobble keyframe \(angle) \(seconds)")
        }
        XCTAssertTrue(mac?.contains("hosting.strokeDistance = max(10, CGFloat(store.floatingPetSize) * 0.15)") == true)
        XCTAssertTrue(mac?.contains("hp.setFrameOrigin(NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.maxY + \(Int(FloatingPetHoverText.gapAbovePet))))") == true)
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar")
    }

    func testTheBubbleAndItsTextAreTheMacs() async {
        for language in AppLanguage.allCases {
            let l = L(language)
            for _ in 0..<40 {
                let a = alert(l), s = summary()
                let shared = FloatingPetBubbles.bubble(limitAlert: a, agent: s)
                let mac = C.bubble(limitAlert: a, agent: s)
                XCTAssertEqual(shared.map(macBubble), mac)
                if let shared, let mac {
                    let content = FloatingPetBubbles.bubbleContent(shared, l: l, measure: Self.macMeasure)
                    let macContent = C.bubbleContent(mac, l: l)
                    XCTAssertEqual(content.title, macContent.title, "\(language) \(shared)")
                    XCTAssertEqual(content.body, macContent.body, "\(language) \(shared)")
                    XCTAssertEqual(content.isCritical, macContent.isCritical)
                }
            }
            for label in labels {
                for count in [nil, "+1", "+7"] {
                    XCTAssertEqual(FloatingPetBubbles.agentTitle(label: label, unlabeled: l.agentWaitingTitle, status: l.agentWaitingStatus, count: count, measure: Self.macMeasure),
                                   C.agentTitle(label: label, unlabeled: l.agentWaitingTitle, status: l.agentWaitingStatus, count: count))
                }
            }
            for message in messages.compactMap({ $0 }) {
                XCTAssertEqual(FloatingPetBubbles.fittedBubbleBody(message, title: l.agentDoneTitle, measure: Self.macMeasure),
                               C.fittedBubbleBody(message, title: l.agentDoneTitle))
            }
        }
    }

    func testTheShowingRulesAreTheMacs() async {
        for _ in 0..<300 {
            let s = summary(), alert = Bool.random(using: &rng), hearts = Bool.random(using: &rng)
            XCTAssertEqual(FloatingPetBubbles.heartsShowing(afterStrokeWithAlertActive: alert, agent: s), C.heartsShowing(afterStrokeWithAlertActive: alert, agent: s))
            XCTAssertEqual(FloatingPetBubbles.isShowingBubble(alertActive: alert, heartsShowing: hearts, agent: s),
                           C.isShowingBubble(alertActive: alert, heartsShowing: hearts, agent: s))
        }
        XCTAssertEqual(FloatingPetBubbles.nativeToolTip("x", heartsShowing: true), C.nativeToolTip("x", heartsShowing: true))
        XCTAssertEqual(FloatingPetBubbles.nativeToolTip("x", heartsShowing: false), C.nativeToolTip("x", heartsShowing: false))
        for seq in [nil, 1, 2] as [Int?] {
            for seen in [nil, 1, 3] as [Int?] {
                for visible in [false, true] {
                    for bubble in [false, true] {
                        XCTAssertEqual(FloatingPetBubbles.shouldPopEvent(eventSeq: seq, lastSeenSeq: seen, petVisible: visible, bubbleShowing: bubble),
                                       C.shouldPopEvent(eventSeq: seq, lastSeenSeq: seen, petVisible: visible, bubbleShowing: bubble))
                    }
                }
            }
        }
    }

    func testTheRunAndTheBobAreTheMacs() async {
        for _ in 0..<2000 {
            let screen = CGRect(x: Double.random(in: -2000...2000, using: &rng).rounded(), y: Double.random(in: -1000...1000, using: &rng).rounded(),
                                width: Double.random(in: 300...3000, using: &rng).rounded(), height: Double.random(in: 200...2000, using: &rng).rounded())
            let cursor = CGPoint(x: screen.minX + Double.random(in: -50...(screen.width + 50), using: &rng).rounded(),
                                 y: screen.minY + Double.random(in: -50...(screen.height + 50), using: &rng).rounded())
            let pet = Double.random(in: 48...384, using: &rng).rounded()
            let size = FloatingPetRules.panelSize(petSize: pet, showingBubble: true)
            let gap = Double.random(in: 0...40, using: &rng).rounded()
            XCTAssertEqual(FloatingPetAgentMotion.runPanelOrigin(cursor: cursor, panelSize: size, visibleFrame: screen, gap: gap),
                           C.runPanelOrigin(cursor: cursor, panelSize: size, visibleFrame: screen, gap: gap))
        }
        let phases: [(FloatingPetRules.RunPhase, C.RunPhase)] = [(.home, .home), (.away, .away), (.returning, .returning)]
        for (shared, mac) in phases {
            for motion in [false, true] {
                for visible in [false, true] {
                    XCTAssertEqual(FloatingPetAgentMotion.runsToCursor(phase: shared, motionAllowed: motion, panelVisible: visible),
                                   C.runsToCursor(phase: mac, motionAllowed: motion, panelVisible: visible))
                }
            }
        }
        for working in [false, true] {
            for motion in [false, true] {
                XCTAssertEqual(FloatingPetAgentMotion.shouldBob(working: working, motionAllowed: motion), C.shouldBob(working: working, motionAllowed: motion))
            }
        }
    }

    func testTheHoverTextIsTheMacs() async {
        for language in AppLanguage.allCases {
            let l = L(language)
            for _ in 0..<60 {
                let tokens = Int.random(in: 0...50_000_000, using: &rng)
                let limit: Double? = Bool.random(using: &rng) ? Double.random(in: 0...120, using: &rng) : nil
                let mode: UsageStore.LimitDisplayMode = Bool.random(using: &rng) ? .used : .remaining
                let sulk = pick([0, 3600 * 5, 3600 * 47, 3600 * 48, 3600 * 24 * 9] as [TimeInterval])
                let event: String? = pick([nil, "Bulbasaur hatched!", "이상해씨가 이상해풀로 진화했어요"])
                let prayers = pick([0, 1, 29, 30, 120])
                let hatchUsed = pick([false, true])
                XCTAssertEqual(FloatingPetHoverText.hoverTooltip(todayTokens: tokens, limitUtilization: limit, mode: mode, l: l, sulkIdle: sulk, eventLine: event, prayers: prayers, prayerHatchUsedToday: hatchUsed),
                               FloatingPetView.hoverTooltip(todayTokens: tokens, limitUtilization: limit, mode: mode, l: l, sulkIdle: sulk, eventLine: event, prayers: prayers, prayerHatchUsedToday: hatchUsed))
            }
        }
    }

    func testStrokesAreDetectedAsTheMacDoes() async {
        for _ in 0..<300 {
            var shared = FloatingPetPetting(), mac = PettingDetector()
            var t = 0.0, x = Double.random(in: 0...500, using: &rng)
            let minStroke = Double.random(in: 4...40, using: &rng).rounded()
            for _ in 0..<60 {
                t += Double.random(in: 0.005...0.4, using: &rng)
                x += Double.random(in: -60...60, using: &rng)
                XCTAssertEqual(shared.feed(x: x, at: t, minStroke: minStroke), mac.feed(x: x, at: t, minStroke: minStroke))
            }
            if Bool.random(using: &rng) { shared.reset(); mac.reset() }
        }
        for pet in [48.0, 60, 66.7, 96, 384] { XCTAssertEqual(FloatingPetStroke.distance(petSize: pet), max(10, pet * 0.15)) }
    }

    func testThePrayerArtAndTheHeartOffsetAreTheMacs() async {
        for pet in stride(from: 40.0, through: 400, by: 7) {
            XCTAssertEqual(FloatingPetPrayerArt.emojiSize(petSize: pet), PrayerEmojiLayer.emojiSize(petSize: pet))
        }
        for _ in 0..<500 {
            let top = Double.random(in: -20...300, using: &rng), height = Double.random(in: 10...60, using: &rng), overlap = Double.random(in: 0...8, using: &rng)
            XCTAssertEqual(FloatingPetHeartArt.bubbleTopOffset(visibleTop: top, bubbleHeight: height, overlap: overlap),
                           SpriteVisibleTop.bubbleTopOffset(visibleTop: top, bubbleHeight: height, overlap: overlap))
        }
    }

    /// The hearts' anchor: the Mac's scan over an NSImage and the twin's over the same pixels as a bitmap, for pictures with
    /// the band's first opaque row anywhere, a band left empty (the whole width decides), faint pixels at the threshold and an
    /// empty picture; the median over frames and the inset in a box.
    func testTheVisibleTopIsTheMacs() async {
        func picture(_ w: Int, _ h: Int, _ alpha: (Int, Int) -> UInt8) -> (NSImage, PlazaBitmap) {
            var bitmap = PlazaBitmap(width: w, height: h)
            for y in 0..<h {
                for x in 0..<w {
                    let a = alpha(x, y)
                    bitmap.bytes[(y * w + x) * 4 + 3] = a
                    bitmap.bytes[(y * w + x) * 4] = a   // premultiplied red
                }
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
            bitmap.bytes.withUnsafeBytes { rep.bitmapData!.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: w * h * 4) }
            let image = NSImage(size: NSSize(width: w, height: h))
            image.addRepresentation(rep)
            return (image, bitmap)
        }
        var cases: [(String, NSImage, PlazaBitmap)] = []
        for top in [0, 1, 7, 20, 41, 63] {
            let (i, b) = picture(64, 64) { x, y in y >= top && x >= 28 && x < 36 ? 255 : 0 }
            cases.append(("band from row \(top)", i, b))
        }
        let (side, sideB) = picture(40, 56) { x, y in y >= 9 && x < 6 ? 200 : 0 }   // only outside the band
        cases.append(("sides only", side, sideB))
        let (faint, faintB) = picture(32, 32) { _, y in y < 10 ? 16 : (y < 12 ? 17 : 0) }   // 16 is not over the threshold
        cases.append(("threshold", faint, faintB))
        let (empty, emptyB) = picture(30, 30) { _, _ in 0 }
        cases.append(("empty", empty, emptyB))
        for _ in 0..<30 {
            let w = Int.random(in: 1...96, using: &rng), h = Int.random(in: 1...96, using: &rng)
            let seed = UInt64.random(in: 0...UInt64.max, using: &rng)
            var g = SeededRNG(seed: seed)
            let rows = (0..<h).map { _ in Bool.random(using: &g) && Bool.random(using: &g) }
            let (i, b) = picture(w, h) { x, y in rows[y] && (x * 7 + y) % 3 == 0 ? UInt8(truncatingIfNeeded: 10 + (x * 37 + y * 11) % 240) : 0 }
            cases.append(("random \(w)x\(h)", i, b))
        }
        for (name, image, bitmap) in cases {
            XCTAssertEqual(FloatingPetVisibleTop.opaqueTopFraction(of: bitmap), SpriteVisibleTop.opaqueTopFraction(of: image), name)
        }
        for _ in 0..<300 {
            let fractions = (0..<Int.random(in: 0...9, using: &rng)).map { _ in CGFloat.random(in: -0.2...1.2, using: &rng) }
            XCTAssertEqual(FloatingPetVisibleTop.anchorFraction(of: fractions), SpriteVisibleTop.anchorFraction(of: fractions))
            let box = CGFloat.random(in: 40...400, using: &rng), size = CGSize(width: Double.random(in: 0...200, using: &rng), height: Double.random(in: 0...200, using: &rng))
            let f = CGFloat.random(in: -0.5...1.5, using: &rng)
            XCTAssertEqual(FloatingPetVisibleTop.inset(box: box, imageSize: size, opaqueTopFraction: f),
                           SpriteVisibleTop.inset(box: box, imageSize: size, opaqueTopFraction: f), accuracy: 1e-9)
        }
    }

    /// The bubble's and the hearts' entrance: the Mac view's transitions and spring (its source), and the twin's curve is
    /// SwiftUI's own spring of that response and damping, and it has settled when the twin stops.
    func testThePopInIsTheMacViewsSpring() async throws {
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("UI/FloatingPetPanel.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: ".animation(animated ? .spring(response: 0.3, dampingFraction: 0.7) : nil,").count - 1, 2)
        XCTAssertTrue(source.contains(".transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))"))
        XCTAssertTrue(source.contains("insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),\n                                removal: .identity))"))
        XCTAssertEqual(FloatingPetPopIn.response, 0.3)
        XCTAssertEqual(FloatingPetPopIn.dampingFraction, 0.7)
        XCTAssertEqual(FloatingPetPopIn.fromScale, 0.8)
        let spring = Spring(response: 0.3, dampingRatio: 0.7)
        for t in stride(from: 0.0, through: 0.8, by: 0.01) {
            XCTAssertEqual(FloatingPetPopIn.progress(at: t), spring.value(target: 1.0, initialVelocity: 0.0, time: t), accuracy: 1e-6, "t=\(t)")
        }
        let end = FloatingPetPopIn.duration
        XCTAssertEqual(spring.value(target: 1.0, initialVelocity: 0.0, time: end), 1, accuracy: 0.002)
        XCTAssertLessThanOrEqual(end, spring.settlingDuration + 0.05)
        XCTAssertEqual(FloatingPetPopIn.scale(at: end), 1)
        XCTAssertEqual(FloatingPetPopIn.opacity(at: 0), 0)
        XCTAssertEqual(FloatingPetPopIn.scale(at: 0), 0.8)
    }

    // MARK: the agent flow against the Mac's controller (its pet hidden: no window on this Mac)

    private func controller() throws -> (C, UsageStore, URL) {
        let suite = "PetExtrasTwin-\(UUID().uuidString)"
        let defaults = TestDefaults.make(suite: suite)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        var state = CompanionState()
        state.active = MonState(baseID: 1, pathIDs: [1], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        let c = C(store: store, companion: companion, defaults: defaults, motionOverride: true)
        c.setDisplayAwake(false)
        store.floatingPetEnabled = true
        return (c, store, file)
    }

    func testTheAgentFlowIsTheMacControllers() async throws {
        for round in 0..<12 {
            let (mac, store, file) = try controller()
            defer { try? FileManager.default.removeItem(at: file) }
            var flow = FloatingPetAgentFlow()
            for _ in 0..<80 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6:
                    let state = pick(["working", "waiting", "done", "idle"])
                    var parts = "poketokenbar://agent?state=\(state)"
                    if let label = pick(["a", "b", "c", nil] as [String?]) { parts += "&label=\(label)" }
                    let event = try XCTUnwrap(AgentActivityEvent(url: try XCTUnwrap(URL(string: parts))))
                    // The Mac controller reads Date() itself; the flow gets Date() a moment later (deadlines microseconds apart).
                    mac.handleAgentEvent(event)
                    _ = flow.handle(event, now: Date(), enabled: store.floatingPetEnabled && store.floatingPetAgentActivity, motionAllowed: true, panelVisible: false)
                case 6, 7:
                    let at = Date().addingTimeInterval(Double.random(in: 0...700, using: &rng))
                    mac.expireAgentActivity(now: at)
                    _ = flow.expire(now: at, motionAllowed: true, panelVisible: false)
                default:
                    mac.petClicked()
                    _ = flow.acknowledge(motionAllowed: true, panelVisible: false)
                }
                XCTAssertEqual(flow.tracker.agents.keys.sorted(), mac.tracker.agents.keys.sorted())
                XCTAssertEqual(flow.tracker.agents.values.map(\.activity).sorted { "\($0)" < "\($1)" }, mac.tracker.agents.values.map(\.activity).sorted { "\($0)" < "\($1)" })
                XCTAssertEqual(flow.summary, mac.tracker.summary)
                XCTAssertEqual(flow.bobs(motionAllowed: true), mac.isBobbing)
                XCTAssertEqual("\(flow.runPhase)", "\(mac.runPhase)")
            }
            _ = round
        }
    }

    func testTheRunAwayAndTheSettingResetAreTheMacControllers() async throws {
        let (mac, store, file) = try controller()
        defer { try? FileManager.default.removeItem(at: file) }
        var flow = FloatingPetAgentFlow()
        let working = try XCTUnwrap(AgentActivityEvent(url: try XCTUnwrap(URL(string: "poketokenbar://agent?state=working"))))
        mac.handleAgentEvent(working)
        _ = flow.handle(working, now: Date(), enabled: true, motionAllowed: true, panelVisible: false)
        _ = mac.beginRun(cursor: NSPoint(x: 600, y: 500), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        flow.beganRun()
        XCTAssertEqual("\(flow.runPhase)", "\(mac.runPhase)")
        store.floatingPetAgentActivity = false
        let deadline = Date().addingTimeInterval(2)
        while mac.tracker.activity != .idle, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(flow.syncReset(enabled: store.floatingPetEnabled && store.floatingPetAgentActivity))
        XCTAssertEqual(flow.tracker.agents.isEmpty, mac.tracker.agents.isEmpty)
        XCTAssertEqual("\(flow.runPhase)", "\(mac.runPhase)")
        XCTAssertNil(flow.deadline)
        XCTAssertNil(mac.agentExpiryFireDate)
    }
}
