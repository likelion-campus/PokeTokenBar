import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// A window that is never shown and reports the backing scale it is given, so a SwiftUI view in it draws at 1x or 2x.
final class ScaledWindow: NSWindow {
    private let factor: CGFloat
    init(scale: CGFloat, size: CGSize) {
        factor = scale
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    }
    override var backingScaleFactor: CGFloat { factor }
}

/// A scroll event with the numbers a test chooses (the system's own cannot be made with a position).
final class MockScrollEvent: NSEvent {
    private let point: NSPoint, dy: CGFloat, precise: Bool
    init(at point: NSPoint, dy: CGFloat, precise: Bool) {
        self.point = point
        self.dy = dy
        self.precise = precise
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { dy }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { precise }
}

/// The view under the panel host in a window: what the host passes a scroll on to.
final class ScrollRecorder: NSView {
    private(set) var passedOn = 0
    override func scrollWheel(with event: NSEvent) { passedOn += 1 }
}

/// The canvas-drawn chat log (Track A Task 17b) against `PlazaChatLogView`, the SwiftUI view the Mac still shows: what the
/// view measures (its hosting view's fitting size), where its lines break and sit, and the pixels in a window at 1x and 2x.
/// The "before" is the real view in a hosting view inside a window that is never shown (a `ScrollView` only draws, and only
/// scrolls to the end, inside a window; `ImageRenderer` leaves it empty), the "after" the panel through the host's layers.
/// With `PTB_PLAZA_HUD_OUT` set it writes before/after images, diffs and a contact sheet into that directory.
@MainActor final class PlazaChatLogPanelRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    private let graphics = PlatformPlaza.graphics
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let korean = "아주 긴 한국어 메시지입니다 줄바꿈이 되는지 확인합니다 여러 번 반복 반복 반복 반복 반복 반복"

    struct Line {
        var name = "나", text = "안녕", color = 0, loud = false
    }

    struct Case {
        var name: String
        var lines: [Line]
        var expanded = false
        var append: Line?          // after the log is shown (expanded: the new line scrolls to the end)
        var viewport = CGSize(width: 960, height: 640)
        var aboveInput: CGFloat?
    }

    static func lines(_ n: Int, _ make: (Int) -> Line = { Line(name: "나\($0)", text: "줄 \($0) hello", color: $0 % 12, loud: $0 % 7 == 3) }) -> [Line] {
        (0..<n).map(make)
    }

    static let cases: [Case] = [
        Case(name: "empty", lines: []),
        Case(name: "one-line", lines: [Line(name: "민수", text: "안녕하세요")]),
        Case(name: "cap-folded", lines: lines(PlazaChatLog.capacity)),
        Case(name: "korean-long", lines: [Line(name: "민수", text: korean), Line(name: "지연", text: "짧아요", color: 3)]),
        Case(name: "latin-unbroken", lines: [Line(name: "bob", text: String(repeating: "abcdefghij", count: 12), color: 2), Line(name: "al", text: "ok", color: 4)]),
        Case(name: "emoji", lines: [Line(name: "고양이", text: "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀", color: 5),
                                    Line(name: "개", text: "🐶 멍멍 🐕 and 🔥 mixed 😀", color: 6, loud: true)]),
        Case(name: "rtl", lines: [Line(name: "שלום", text: "שלום עולם זה טקסט ארוך מאוד בעברית שמתפרש על כמה שורות כדי לבדוק", color: 7),
                                  Line(name: "mix", text: "English ואז עברית then 한국어 and back", color: 8)]),
        Case(name: "colours-0-5", lines: lines(6) { Line(name: "색\($0)", text: "이름 색 \($0)", color: $0) }),
        Case(name: "colours-6-11", lines: lines(6) { Line(name: "색\($0 + 6)", text: "이름 색 \($0 + 6)", color: $0 + 6) }),
        Case(name: "mixed", lines: [Line(name: "a", text: korean, color: 1), Line(name: "민수", text: "short", color: 2, loud: true),
                                    Line(name: "d", text: String(repeating: "x", count: 130), color: 9, loud: true), Line(name: "e", text: "😀 emoji 한국어 ok", color: 10),
                                    Line(name: "f", text: "שלום", color: 11), Line(name: "긴이름긴이름긴이름", text: "ok", color: 0)]),
        Case(name: "above-input", lines: lines(3), aboveInput: 28),
        Case(name: "expanded-3", lines: lines(3), expanded: true),
        Case(name: "expanded-50", lines: lines(50), expanded: true),
        Case(name: "expanded-long", lines: lines(20) { Line(name: "나\($0)", text: $0 % 3 == 0 ? korean : "줄 \($0)", color: $0 % 12, loud: $0 % 5 == 1) }, expanded: true),
        Case(name: "expanded-append", lines: lines(30), expanded: true, append: Line(name: "새", text: "방금 온 줄입니다", color: 4)),
        Case(name: "small-window", lines: lines(4), viewport: CGSize(width: 600, height: 372)),
    ]

    private func log(_ c: Case) -> PlazaChatLog {
        let log = PlazaChatLog()
        for l in c.lines { add(l, to: log) }
        log.isExpanded = c.expanded
        return log
    }

    private func add(_ l: Line, to log: PlazaChatLog) {
        log.append(time: Self.now, name: l.name, text: l.text, color: PlazaNameColor.palette[l.color], isLoud: l.loud)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    // MARK: before: the SwiftUI view

    @MainActor final class Before {
        let host: NSHostingView<PlazaChatLogView>, window: ScaledWindow, log: PlazaChatLog
        init(_ log: PlazaChatLog, scale: CGFloat) {
            self.log = log
            host = NSHostingView(rootView: PlazaChatLogView(log: log))
            window = ScaledWindow(scale: scale, size: host.fittingSize)
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        var size: CGSize { host.fittingSize }
        /// The view as drawn (a log that is empty draws nothing: opacity 0).
        func image(scale: CGFloat) throws -> CGImage {
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.cgImage)
        }
    }

    private func before(_ c: Case, scale: CGFloat) async throws -> (image: CGImage, size: CGSize) {
        let log = log(c)
        let b = Before(log, scale: scale)
        await settle()
        if let extra = c.append { add(extra, to: log); await settle() }
        let size = b.size
        let placed = K.context(Int(c.viewport.width * scale), Int(c.viewport.height * scale))
        let shown = try b.image(scale: scale)
        XCTAssertEqual(shown.width, Int(size.width * scale), "\(c.name): the capture is at \(scale)x")
        // Where the old constraints put it: 16 from the left, 16 above the bottom (above the chat field when it is open).
        let bottom = 16 + (c.aboveInput.map { $0 + 8 } ?? 0)
        placed.draw(shown, in: CGRect(x: 16 * scale, y: bottom * scale, width: size.width * scale, height: size.height * scale))
        return (try XCTUnwrap(placed.makeImage()), size)
    }

    // MARK: after: the panel through its host

    @MainActor final class Shell: PlazaPanelHost {
        var hosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) { hosts[id]?.show(drawing: drawing, frame: frame, scale: scale) }
        func hide(_ id: PlazaPanelID) { hosts[id]?.hide() }
    }

    @MainActor final class After {
        let log: PlazaChatLog, panel: PlazaChatLogPanel, hud: PlazaHUD, host: PlazaPanelHostView, container: NSView
        let shell = Shell()
        init(_ log: PlazaChatLog, viewport: CGSize, scale: CGFloat, aboveInput: CGFloat?, graphics: any PlazaGraphics) {
            self.log = log
            panel = PlazaChatLogPanel(log: log)
            panel.inputHeight = aboveInput
            hud = PlazaHUD(panels: [panel], graphics: graphics)
            container = NSView(frame: CGRect(origin: .zero, size: viewport))
            host = PlazaPanelHostView(hud: hud, panel: .chatLog)
            host.frame = container.bounds
            container.addSubview(host)
            shell.hosts[.chatLog] = host
            hud.setViewport(viewport, scale: scale)
            hud.host = shell
        }
        func image(_ viewport: CGSize, scale: CGFloat) throws -> CGImage {
            let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            try XCTUnwrap(host.layer).render(in: ctx)
            return try XCTUnwrap(ctx.makeImage())
        }
        var frame: CGRect? { hud.layout(viewport: hud.viewport, scale: hud.scale)[.chatLog] }
    }

    private func after(_ c: Case, scale: CGFloat) async throws -> (image: CGImage, frame: CGRect?, rig: After) {
        let log = log(c)
        let a = After(log, viewport: c.viewport, scale: scale, aboveInput: c.aboveInput, graphics: graphics)
        if let extra = c.append { add(extra, to: log); for _ in 0..<20 { await Task.yield() } }
        return (try a.image(c.viewport, scale: scale), a.frame, a)
    }

    // MARK: frames

    /// The panel is as big, and where, SwiftUI's hosting view was (the old constraints: 16 from the left, bottom at
    /// the window's bottom less 16, or 8 above the chat field). Pinned: what SwiftUI measured.
    func testPanelFramesAreTheHostingViewFramesSwiftUIHad() async throws {
        for c in Self.cases where !c.lines.isEmpty {
            for scale in [CGFloat(1), 2] {
                let b = Before(log(c), scale: scale)
                await settle()
                let size = b.size
                let a = try await after(c, scale: scale)
                let bottom = c.viewport.height - 16 - (c.aboveInput.map { $0 + 8 } ?? 0)
                XCTAssertEqual(a.frame, CGRect(x: 16, y: bottom - size.height, width: size.width, height: size.height), "\(c.name)@\(scale): SwiftUI measured \(size)")
                print("FRAME \(c.name)@\(Int(scale))x \(size)")
            }
        }
        // Pinned: the real font's numbers (header 14 tall, a line 18).
        let one = Before(log(Self.cases[1]), scale: 2)
        await settle()
        XCTAssertEqual(one.size, CGSize(width: 360, height: 8 + 14 + 4 + 18 + 8))
        let exp = Before(log(Self.cases[11]), scale: 2)
        await settle()
        XCTAssertEqual(exp.size, CGSize(width: 360, height: 8 + 14 + 4 + PlazaChatLog.expandedHeight + 8))
    }

    // MARK: breaks and positions

    /// The bands of ink inside the text area (pixels, top-left): one per run of rows that holds a pixel differing from the
    /// plate's colour, with its horizontal extent. A line that broke somewhere else, a row that sits a pixel lower, a
    /// different line height: each moves a band.
    private func bands(_ image: CGImage, frame: CGRect, scale: CGFloat) -> [CGRect] {
        let px = K.rgba(image), w = image.width
        let x0 = Int((frame.minX + 10) * scale), x1 = Int((frame.maxX - 10) * scale)
        let y0 = Int((frame.minY + 8 + 14 + 4) * scale), y1 = Int((frame.maxY - 8) * scale)
        let bg = Array(px[((y0 + 1) * w + x0 - 4) * 4..<((y0 + 1) * w + x0 - 4) * 4 + 4])
        func ink(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return (0..<4).contains { abs(Int(px[i + $0]) - Int(bg[$0])) > 48 }
        }
        var out: [CGRect] = []
        var y = y0
        while y < y1 {
            guard (x0..<x1).contains(where: { ink($0, y) }) else { y += 1; continue }
            let top = y
            var lo = x1, hi = x0
            while y < y1, (x0..<x1).contains(where: { ink($0, y) }) {
                for x in x0..<x1 where ink(x, y) { lo = min(lo, x); hi = max(hi, x + 1) }
                y += 1
            }
            let band = CGRect(x: lo, y: top, width: hi - lo, height: y - top)
            // One blank pixel row between two bands is antialiasing, not a gap between lines (colour emoji edges).
            if let last = out.last, band.minY - last.maxY <= 1 { out[out.count - 1] = last.union(band) } else { out.append(band) }
        }
        return out
    }

    /// Every line of every case breaks where SwiftUI broke it, and sits where it sat: the bands of ink (a line's rows, its
    /// left and right ends) are the same to within 2 device pixels. The expanded cases show the scroll position too (the
    /// SwiftUI view scrolled itself to the end, as the panel does).
    func testLineBreaksAndRowPositionsAreSwiftUIs() async throws {
        for c in Self.cases where !c.lines.isEmpty {
            for scale in [CGFloat(1), 2] {
                let (b, size) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                let frame = try XCTUnwrap(a.frame)
                let bottom = c.viewport.height - 16 - (c.aboveInput.map { $0 + 8 } ?? 0)
                let sBands = bands(b, frame: CGRect(x: 16, y: bottom - size.height, width: size.width, height: size.height), scale: scale)
                let pBands = bands(a.image, frame: frame, scale: scale)
                XCTAssertEqual(pBands.count, sBands.count, "\(c.name)@\(scale): the number of line bands")
                for (s, p) in zip(sBands, pBands) {
                    XCTAssertEqual(p.minY, s.minY, accuracy: 2 * scale, "\(c.name)@\(scale) top of a band")
                    XCTAssertEqual(p.maxY, s.maxY, accuracy: 2 * scale, "\(c.name)@\(scale) bottom of a band")
                    XCTAssertEqual(p.minX, s.minX, accuracy: 2 * scale, "\(c.name)@\(scale) left end")
                    XCTAssertEqual(p.maxX, s.maxX, accuracy: 2 * scale, "\(c.name)@\(scale) right end")
                }
                print("BANDS \(c.name)@\(Int(scale))x swiftui \(sBands.map { "\(Int($0.minY))-\(Int($0.maxY)) x\(Int($0.minX))-\(Int($0.maxX))" }) panel \(pBands.map { "\(Int($0.minY))-\(Int($0.maxY)) x\(Int($0.minX))-\(Int($0.maxX))" })")
            }
        }
    }

    // MARK: pixels

    /// The pixels in a window against SwiftUI's at 1x and 2x. The bounds are what the first run measured, with room.
    func testPanelLooksLikeItsSwiftUIOriginal() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let (b, _) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                let d = K.diff(b, a.image)
                print("ERR \(c.name)@\(Int(scale))x over8 \(d.over8) over64 \(d.over64) max \(d.max)")
                if c.lines.isEmpty { XCTAssertEqual(d.max, 0, "an empty log draws nothing, as SwiftUI's opacity 0") }
                // Text, plate and colours match to the pixel except the antialiased corners of the plate and, where there is
                // colour emoji, the emoji (SwiftUI draws them half a point lower: the same difference Task 14 listed). A
                // line with a few emoji stays small; a stress line of thirty is the one that is large.
                let (limit8, limit64): (Int, Int) = c.name == "emoji" ? (30_000, 8_000) : c.name == "mixed" ? (800, 120) : (100, 40)
                XCTAssertLessThan(d.over8, limit8, "\(c.name)@\(scale): \(d.over8) pixels off by more than 8")
                XCTAssertLessThan(d.over64, limit64, "\(c.name)@\(scale): \(d.over64) pixels off by more than 64")
            }
        }
    }

    // MARK: clicks

    /// Where a click lands on the SwiftUI view (its hosting view's `hitTest`, probed every 2 points over the log and 12
    /// points around it) and on the panel. Prints the mismatches.
    func testClicksLandWhereTheyDidOnTheSwiftUIView() async throws {
        for c in [Self.cases[1], Self.cases[2], Self.cases[11], Self.cases[12]] {
            let log = log(c)
            let host = PlazaChatLogHostingView(rootView: PlazaChatLogView(log: log), log: log)
            let window = ScaledWindow(scale: 2, size: c.viewport)
            let container = NSView(frame: CGRect(origin: .zero, size: c.viewport))
            window.contentView = container
            container.addSubview(host)
            let size = host.fittingSize
            host.frame = CGRect(x: 16, y: 16, width: size.width, height: size.height)   // bottom left, as its constraints put it
            container.layoutSubtreeIfNeeded()
            await settle()
            let a = try await after(c, scale: 2)
            let frame = try XCTUnwrap(a.frame)
            var swiftOnly = 0, panelOnly = 0, both = 0
            var sample: [String] = []
            for y in stride(from: frame.minY - 12, to: frame.maxY + 12, by: 2) {
                for x in stride(from: frame.minX - 12, to: frame.maxX + 12, by: 2) {
                    let sw = host.hitTest(NSPoint(x: x, y: c.viewport.height - y)) != nil
                    let pn = a.rig.hud.hit(at: CGPoint(x: x, y: y), in: .chatLog) != nil
                    if sw && pn { both += 1 } else if sw { swiftOnly += 1; if sample.count < 6 { sample.append("sw(\(x - frame.minX),\(y - frame.minY))") } }
                    else if pn { panelOnly += 1; if sample.count < 6 { sample.append("pn(\(x - frame.minX),\(y - frame.minY))") } }
                }
            }
            print("CLICK \(c.name) both \(both) swiftuiOnly \(swiftOnly) panelOnly \(panelOnly) \(sample)")
        }
        let empty = PlazaChatLog()
        let host = PlazaChatLogHostingView(rootView: PlazaChatLogView(log: empty), log: empty)
        host.frame = CGRect(x: 16, y: 16, width: 360, height: 100)
        XCTAssertNil(host.hitTest(NSPoint(x: 100, y: 50)), "an empty log let clicks through")
        XCTAssertFalse(PlazaChatLogPanel(log: empty).isVisible, "and the panel takes none")
    }

    // MARK: the wheel through the Mac host

    /// The host gives a scroll to the panel: consumed while the log can move that way, passed on up the responder chain at
    /// the ends and when the log is folded, as the SwiftUI `ScrollView` did (nothing behind the log listens to the wheel:
    /// the plaza zooms with keys, so a passed-on scroll ends at the window).
    func testTheHostPassesTheWheelOnAtTheEnds() async throws {
        for (name, expanded) in [("unfolded", true), ("folded", false)] {
            let c = Case(name: name, lines: Self.lines(50), expanded: expanded)
            let a = try await after(c, scale: 2).rig
            let recorder = ScrollRecorder(frame: CGRect(origin: .zero, size: c.viewport))
            let window = ScaledWindow(scale: 2, size: c.viewport)
            window.contentView = recorder
            a.host.removeFromSuperview()
            a.host.frame = recorder.bounds
            recorder.addSubview(a.host)
            let frame = try XCTUnwrap(a.frame)
            let inside = NSPoint(x: frame.midX, y: c.viewport.height - frame.midY)   // window coordinates: y up
            func wheel(_ dy: CGFloat, precise: Bool = true) -> Bool {
                let before = recorder.passedOn
                a.host.scrollWheel(with: MockScrollEvent(at: inside, dy: dy, precise: precise))
                return recorder.passedOn == before   // consumed
            }
            if !expanded {
                XCTAssertFalse(wheel(30), "folded: nothing to scroll, passed on")
                continue
            }
            XCTAssertFalse(wheel(-30), "at the bottom, further down is passed on")
            XCTAssertTrue(wheel(30), "up: the log takes it")
            XCTAssertEqual(a.panel.scrollState.offset, 657 - 30 + (a.panel.scrollState.maxOffset - 657), accuracy: 0.001)
            let offset = a.panel.scrollState.offset
            XCTAssertTrue(wheel(1, precise: false), "a notched wheel's line")
            XCTAssertEqual(a.panel.scrollState.offset, offset - PlazaPanelHostView.lineScrollStep, accuracy: 0.001, "a line is \(PlazaPanelHostView.lineScrollStep) points")
            XCTAssertTrue(wheel(10_000))
            XCTAssertTrue(a.panel.scrollState.isAtTop)
            XCTAssertFalse(wheel(30), "at the top, further up is passed on")
            // Outside the log the host is not even asked (its hitTest is nil there).
            XCTAssertNil(a.host.hitTest(NSPoint(x: 600, y: 300)))
        }
    }

    // MARK: cost

    /// How often the panel renders and what a render costs (a debug build, real CoreText): ten new lines arriving, a
    /// second of wheel events, an idle plaza, a hidden one. Never per frame.
    func testRenderCountsAndCosts() async throws {
        let scale: CGFloat = 2
        let viewport = CGSize(width: 960, height: 640)
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func make(expanded: Bool, lines: Int) -> After {
            let log = PlazaChatLog()
            for i in 0..<lines { add(Line(name: "나\(i)", text: i % 5 == 4 ? Self.korean : "줄 \(i) hello", color: i % 12, loud: i % 7 == 3), to: log) }
            log.isExpanded = expanded
            let a = After(log, viewport: viewport, scale: scale, aboveInput: nil, graphics: graphics)
            return a
        }
        let clock = ContinuousClock()

        // Ten lines arriving one after the other, a turn apart: each renders once. Folded and unfolded.
        for expanded in [false, true] {
            let a = make(expanded: expanded, lines: 20)
            for _ in 0..<20 { await Task.yield() }
            let base = a.hud.renderCounts[.chatLog] ?? 0
            let start = clock.now
            for i in 0..<10 {
                add(Line(name: "새\(i)", text: i % 3 == 0 ? Self.korean : "새 줄 \(i)", color: i), to: a.log)
                for _ in 0..<20 { await Task.yield() }
            }
            let elapsed = ms(start.duration(to: clock.now))
            let renders = (a.hud.renderCounts[.chatLog] ?? 0) - base
            print("COST ten lines (\(expanded ? "unfolded" : "folded")): \(renders) renders, \(String(format: "%.2f", elapsed / Double(max(renders, 1)))) ms each (incl. 20 yields)")
            XCTAssertEqual(renders, 10)
        }
        // Ten lines in one turn: one render.
        do {
            let a = make(expanded: true, lines: 20)
            for _ in 0..<20 { await Task.yield() }
            let base = a.hud.renderCounts[.chatLog] ?? 0
            for i in 0..<10 { add(Line(name: "새\(i)", text: "새 줄 \(i)", color: i), to: a.log) }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual((a.hud.renderCounts[.chatLog] ?? 0) - base, 1)
        }
        // A second of wheel events (120 a second, as a trackpad sends them): one render each, never more.
        do {
            let a = make(expanded: true, lines: 50)
            for _ in 0..<20 { await Task.yield() }
            let frame = try XCTUnwrap(a.frame)
            let p = CGPoint(x: frame.midX, y: frame.midY)
            let base = a.hud.renderCounts[.chatLog] ?? 0
            var consumed = 0
            var worst = 0.0, total = 0.0
            for i in 0..<120 {
                let t0 = clock.now
                if a.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: i < 100 ? 4 : -4), location: p), in: .chatLog) { consumed += 1 }
                await Task.yield()
                for _ in 0..<5 { await Task.yield() }
                let d = ms(t0.duration(to: clock.now))
                total += d
                worst = max(worst, d)
            }
            let renders = (a.hud.renderCounts[.chatLog] ?? 0) - base
            print("COST wheel 1 s: 120 events, \(consumed) consumed, \(renders) renders, \(String(format: "%.2f", total / Double(max(renders, 1)))) ms each, worst \(String(format: "%.2f", worst)) ms")
            XCTAssertEqual(renders, consumed, "one render per event that moved the log")
        }
        // Idle and hidden: nothing.
        do {
            let a = make(expanded: true, lines: 50)
            for _ in 0..<20 { await Task.yield() }
            let base = a.hud.renderCounts[.chatLog] ?? 0
            for _ in 0..<500 { await Task.yield() }
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(a.hud.renderCounts[.chatLog] ?? 0, base, "an idle visible plaza: no render for this panel")
            a.hud.isRendering = false
            add(Line(name: "숨김", text: "숨겨진 동안 온 줄", color: 1), to: a.log)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(a.hud.renderCounts[.chatLog] ?? 0, base, "a hidden plaza: none")
            print("COST idle 1 s: 0 renders; hidden: 0 renders")
        }
        // The first render of a big log (cold: wrapping 50 lines, drawing the visible rows).
        do {
            let t0 = clock.now
            let a = make(expanded: true, lines: 50)   // the host attaches and the panel renders inside `After.init`
            let cold = ms(t0.duration(to: clock.now))
            XCTAssertEqual(a.hud.renderCounts[.chatLog], 1)
            print("COST cold open (50 lines unfolded: wrap all, draw the visible rows, host): \(String(format: "%.1f", cold)) ms")
        }
    }

    // MARK: images

    /// Writes before/after PNGs (over the plaza map and over a checkerboard, for a transparent background), diffs and one
    /// contact sheet into `PTB_PLAZA_HUD_OUT`.
    func testWriteChatLogImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        func background(_ v: CGSize, _ scale: CGFloat) -> CGImage {
            let ctx = K.context(Int(v.width * scale), Int(v.height * scale))
            ctx.interpolationQuality = .none
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            ctx.draw(map.cgImage, in: CGRect(x: -300 * scale, y: v.height * scale - size.height + 200 * scale, width: size.width, height: size.height))
            return ctx.makeImage()!
        }
        var summary: [String] = [], rows: [(label: String, cells: [CGImage])] = []
        for c in Self.cases where !c.lines.isEmpty {
            for scale in [CGFloat(2), 1] {
                let (b, size) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                let bottom = c.viewport.height - 16 - (c.aboveInput.map { $0 + 8 } ?? 0)
                let crop = CGRect(x: 8, y: bottom - size.height - 8, width: size.width + 16, height: size.height + 16)
                let tag = "\(c.name)@\(Int(scale))x"
                let bg = background(c.viewport, scale)
                let zoom = scale == 1 ? 2 : 1
                let cells = [K.cell(b, crop: crop, scale: scale, background: bg, zoom: zoom), K.cell(a.image, crop: crop, scale: scale, background: bg, zoom: zoom),
                             K.cell(b, crop: crop, scale: scale, background: nil, zoom: zoom), K.cell(a.image, crop: crop, scale: scale, background: nil, zoom: zoom)]
                let d = K.diff(K.cell(b, crop: crop, scale: scale, background: nil, zoom: 1), K.cell(a.image, crop: crop, scale: scale, background: nil, zoom: 1))
                try K.write(cells[0], out.appendingPathComponent("before-\(tag)-default.png"))
                try K.write(cells[1], out.appendingPathComponent("after-\(tag)-default.png"))
                try K.write(cells[2], out.appendingPathComponent("before-\(tag)-transparent.png"))
                try K.write(cells[3], out.appendingPathComponent("after-\(tag)-transparent.png"))
                try K.write(d.image, out.appendingPathComponent("diff-\(tag).png"))
                let line = "\(tag): pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
                summary.append(line)
                let zoomed = K.cell(d.image, crop: CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / scale, height: CGFloat(d.image.height) / scale),
                                    scale: scale, background: nil, zoom: zoom)
                rows.append((line, cells + [zoomed]))
            }
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try K.write(K.sheet(rows, columns: ["before · plaza", "after · plaza", "before · transparent", "after · transparent",
                                            "diff (magenta: a channel off by more than 8)"]), out.appendingPathComponent("contact-sheet.png"))
    }
}
