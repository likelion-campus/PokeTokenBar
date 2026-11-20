import AppKit
import XCTest
@testable import PokeTokenBar

/// The floating pet's shared twins (stage 7 Task 22, `Popover/FloatingPetRules.swift`, `Popover/PopoverSpriteFrameCap.swift`)
/// against the Mac's own members in `UI/FloatingPetPanel.swift` and `UI/SpriteAnimation.swift`: each pair over the same
/// inputs. `twins.txt` holds the bodies together; this proves the behaviour (a corpus the text scan cannot see).
@MainActor
final class PopoverPetTwinEquivalenceTests: XCTestCase {
    private var rng = SeededRNG(seed: 22)

    private func value(_ range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat(Double.random(in: Double(range.lowerBound)...Double(range.upperBound), using: &rng)).rounded()
    }

    func testTheConstantsAndKeysAreTheMacs() async throws {
        XCTAssertEqual(FloatingPetRules.clickThresholdSquared, FloatingPetController.clickThresholdSquared)
        XCTAssertEqual(FloatingPetRules.bubbleHeadroom, FloatingPetController.bubbleHeadroom)
        XCTAssertEqual(FloatingPetRules.bubbleMinWidth, FloatingPetController.bubbleMinWidth)
        XCTAssertEqual(FloatingPetRules.prayersPerRefresh, FloatingPetController.prayersPerRefresh)
        XCTAssertEqual(FloatingPetRules.prayerRefreshInterval, FloatingPetController.prayerRefreshInterval)
        let mac = try Self.macSource("UI/FloatingPetPanel.swift")
        XCTAssertTrue(mac.contains("private static let originXKey = \"\(FloatingPetOrigin.originXKey)\""), "the Mac's saved-origin X key changed")
        XCTAssertTrue(mac.contains("private static let originYKey = \"\(FloatingPetOrigin.originYKey)\""), "the Mac's saved-origin Y key changed")
        XCTAssertTrue(mac.contains("return NSPoint(x: visible.maxX - petSize - 24, y: visible.minY + 24)"), "the Mac's default corner changed")
        XCTAssertEqual(FloatingPetPlacement.defaultMargin, 24)
        XCTAssertTrue(mac.contains("guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 120, y: 120) }"))
        XCTAssertEqual(FloatingPetPlacement.noScreenOrigin, CGPoint(x: 120, y: 120))
    }

    func testTheGeometryIsTheMacs() async {
        for _ in 0..<2000 {
            let a = CGPoint(x: value(-500...500), y: value(-500...500)), b = CGPoint(x: a.x + value(-6...6), y: a.y + value(-6...6))
            let t = value(1...40)
            XCTAssertEqual(FloatingPetRules.isClick(from: a, to: b), FloatingPetController.isClick(from: a, to: b))
            XCTAssertEqual(FloatingPetRules.isClick(from: a, to: b, thresholdSquared: t), FloatingPetController.isClick(from: a, to: b, thresholdSquared: t))
            let pet = value(48...384)
            for bubble in [false, true] {
                let size = FloatingPetRules.panelSize(petSize: pet, showingBubble: bubble)
                XCTAssertEqual(size, FloatingPetController.panelSize(petSize: pet, showingBubble: bubble))
                XCTAssertEqual(FloatingPetRules.panelOrigin(petOrigin: a, petSize: pet, panelSize: size),
                               FloatingPetController.panelOrigin(petOrigin: a, petSize: pet, panelSize: size))
                XCTAssertEqual(FloatingPetRules.petOrigin(panelOrigin: a, petSize: pet, panelSize: size),
                               FloatingPetController.petOrigin(panelOrigin: a, petSize: pet, panelSize: size))
                XCTAssertEqual(FloatingPetPlacement.savedPetOrigin(panelOrigin: a, petSize: pet, showingBubble: bubble),
                               FloatingPetController.petOrigin(panelOrigin: a, petSize: pet, panelSize: size), "panelDidMove's saved origin")
            }
        }
    }

    func testTheClickAndMotionRulesAreTheMacs() async {
        for egg in [false, true] {
            XCTAssertEqual(FloatingPetRules.clickAction(subjectIsEgg: egg) == .pray, FloatingPetController.clickAction(subjectIsEgg: egg) == .pray)
        }
        for low in [false, true] { XCTAssertEqual(FloatingPetRules.shouldAnimate(lowPower: low), FloatingPetController.shouldAnimate(lowPower: low)) }
        for animated in [false, true] {
            for reduce in [false, true] {
                XCTAssertEqual(FloatingPetRules.allowsMotion(animated: animated, reduceMotion: reduce),
                               FloatingPetController.allowsMotion(animated: animated, reduceMotion: reduce))
            }
        }
        let phases: [(FloatingPetRules.RunPhase, FloatingPetController.RunPhase)] = [(.home, .home), (.away, .away), (.returning, .returning)]
        for (twin, mac) in phases {
            for dragging in [false, true] {
                let a = FloatingPetRules.resolveMove(phase: twin, userDragging: dragging), b = FloatingPetController.resolveMove(phase: mac, userDragging: dragging)
                XCTAssertEqual(a.persist, b.persist)
                XCTAssertEqual("\(a.phase)", "\(b.phase)")
            }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for count in -3...200 {
            XCTAssertEqual(FloatingPetRules.prayerRefreshMilestone(for: count), FloatingPetController.prayerRefreshMilestone(for: count))
            for last in 0...4 {
                for since in [nil, 0, 10, 29.9, 30, 31, 600] as [TimeInterval?] {
                    let at = since.map { now.addingTimeInterval(-$0) }
                    XCTAssertEqual(FloatingPetRules.shouldRefreshOnPrayer(count: count, lastRefreshedMilestone: last, lastRefreshAt: at, now: now),
                                   FloatingPetController.shouldRefreshOnPrayer(count: count, lastRefreshedMilestone: last, lastRefreshAt: at, now: now))
                }
            }
        }
    }

    /// The same click sequence (eggs and hatched, prayers past milestones, a new egg starting over, time moving in steps)
    /// through the Mac's `PetClickRouter` and the twin: the same calls in the same order.
    func testTheClickRouterIsTheMacs() async {
        final class Log { var calls: [String] = []; var count = 0; var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let mac = Log(), twin = Log()
        let a = PetClickRouter(pray: { mac.count += 1; mac.calls.append("pray") }, prayerCount: { mac.count }, didPray: { mac.calls.append("didPray") },
                               spawnEmoji: { mac.calls.append("emoji") }, refreshUsage: { mac.calls.append("refresh") },
                               openPopover: { mac.calls.append("open") }, clock: { mac.now })
        let b = PopoverPetClickRouter(pray: { twin.count += 1; twin.calls.append("pray") }, prayerCount: { twin.count }, didPray: { twin.calls.append("didPray") },
                                      spawnEmoji: { twin.calls.append("emoji") }, refreshUsage: { twin.calls.append("refresh") },
                                      openPopover: { twin.calls.append("open") }, clock: { twin.now })
        var r = SeededRNG(seed: 7)
        for step in 0..<600 {
            let egg = Int.random(in: 0..<10, using: &r) > 1
            let advance = TimeInterval(Int.random(in: 0...4, using: &r))
            if step == 300 { mac.count = 0; twin.count = 0 }   // a new egg
            mac.now = mac.now.addingTimeInterval(advance)
            twin.now = twin.now.addingTimeInterval(advance)
            a.handle(subjectIsEgg: egg)
            b.handle(subjectIsEgg: egg)
        }
        XCTAssertEqual(mac.calls, twin.calls)
        XCTAssertTrue(mac.calls.contains("refresh") && mac.calls.contains("open"), "the corpus reaches both branches")
    }

    func testTheFrameCapIsTheMacs() async {
        let macImages = (0..<60).map { _ in NSImage(size: NSSize(width: 1, height: 1)) }
        let twinImages = (0..<60).map { _ in PlazaImage(bitmap: PlazaBitmap(width: 1, height: 1)) }
        var r = SeededRNG(seed: 3)
        var corpora: [[TimeInterval]] = [[], [0.1], Array(repeating: 0.05, count: 55), Array(repeating: 0.1, count: 4), [0.03, 0.5, 0.02, 0.07, 0.3],
                                         Array(repeating: 0.02, count: 37)]
        for _ in 0..<200 {
            corpora.append((0..<Int.random(in: 0...40, using: &r)).map { _ in [0.02, 0.03, 0.05, 0.06, 0.08, 0.1, 0.15, 0.2, 0.5][Int.random(in: 0..<9, using: &r)] })
        }
        for delays in corpora {
            for floor in [0, 0.05, 0.1, 0.2, 0.4, 1.0] as [TimeInterval] {
                let mac = GIFDecoder.capFrameRate(delays.enumerated().map { (macImages[$0.offset], $0.element) }, floor: floor)
                let twin = PopoverSpriteFrameCap.capFrameRate(delays.enumerated().map { (twinImages[$0.offset], $0.element) }, floor: floor)
                XCTAssertEqual(mac.map { macImages.firstIndex(of: $0.image) }, twin.map { f in twinImages.firstIndex { $0 === f.image } }, "\(delays) at \(floor)")
                XCTAssertEqual(mac.map(\.delay), twin.map(\.delay), "\(delays) at \(floor)")
            }
        }
    }

    /// `FloatingPetController.targetFrame` with the screens and the saved origin as arguments: the shared placement over random
    /// screens, homes and sizes (bubbles too), each case on the Mac's own rule.
    func testTheTargetFrameIsTheMacs() async {
        for _ in 0..<3000 {
            let screens = (0..<Int.random(in: 0...3, using: &rng)).map { _ in
                NSRect(x: value(-3000...3000), y: value(-1500...1500), width: value(640...2560), height: value(400...1440))
            }
            let main = screens.isEmpty || Bool.random(using: &rng) && screens.count > 1 ? screens.last : screens.first
            let pet = value(48...384)
            let saved: NSPoint? = Bool.random(using: &rng) ? NSPoint(x: value(-6000...6000), y: value(-3000...3000)) : nil
            let away: NSPoint? = Int.random(in: 0..<5, using: &rng) == 0 ? NSPoint(x: value(-6000...6000), y: value(-3000...3000)) : nil
            let bubble = Bool.random(using: &rng)
            let mac = MacPetOracle.targetFrame(away: away, saved: saved, petSize: pet, showingBubble: bubble, visibleFrames: screens, mainVisible: main)
            let twin = FloatingPetPlacement.targetFrame(away: away, saved: saved, petSize: pet, showingBubble: bubble, visibleFrames: screens, mainVisible: main)
            XCTAssertEqual(twin.frame, mac, "saved \(String(describing: saved)) away \(String(describing: away)) pet \(pet) screens \(screens)")
            XCTAssertEqual(FloatingPetPlacement.defaultPetOrigin(petSize: pet, mainVisible: main), MacPetOracle.defaultPetOrigin(petSize: pet, mainVisible: main))
        }
    }

    /// What the model reads is what the Mac's pet reads (the pins in twins.txt catch a change in these bodies; these name the
    /// arguments the model mirrors, so a reviewer sees which ones).
    func testTheModelReadsWhatTheMacPetReads() async throws {
        let mac = try Self.macSource("UI/FloatingPetPanel.swift")
        XCTAssertTrue(mac.contains("guard store.floatingPetEnabled, displayAwake else { hide(); return }"), "sync's show rule")
        XCTAssertTrue(mac.contains("let wantAnimated = Self.shouldAnimate(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)"), "show's animated rule")
        XCTAssertTrue(mac.contains("let size = CGFloat(store.floatingPetSize)\n        let subject = companion.representativeSubject"), "the view's size and subject")
        XCTAssertTrue(mac.contains("SpriteView(speciesID: subject.speciesID, size: size, animated: animated,\n                       shiny: subject.isShiny,\n"
                                   + "                       minFrameDelay: store.animationQuality.frameFloor, spriteStore: spriteStore, form: subject.form,\n"
                                   + "                       back: companion.facesBack, reportsVisibleTop: true)"), "the sprite's arguments")
        // The menu: Open, Hide, Back view (checked by the setting), in that order.
        let open = try XCTUnwrap(mac.range(of: "addItem(withTitle: l.floatingPetMenuOpen"))
        let hide = try XCTUnwrap(mac.range(of: "addItem(withTitle: l.floatingPetMenuHide"))
        let back = try XCTUnwrap(mac.range(of: "addItem(withTitle: l.backViewLabel"))
        XCTAssertTrue(open.lowerBound < hide.lowerBound && hide.lowerBound < back.lowerBound)
        XCTAssertTrue(mac.contains("backView.state = isBackViewOn() ? .on : .off"))
        XCTAssertEqual(FloatingPetMenu.entries(l: L(.en), backViewOn: true).map(\.title), [L(.en).floatingPetMenuOpen, L(.en).floatingPetMenuHide, L(.en).backViewLabel])
        // The app's hide is the setting off.
        XCTAssertTrue(try Self.macSource("PokeTokenBarApp.swift").contains("onHide: { [weak self] in self?.store.floatingPetEnabled = false }"))
    }

    static func macSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/PokeTokenBar").appendingPathComponent(relative), encoding: .utf8)
    }
}

/// `FloatingPetController.targetFrame` and `defaultPetOrigin` with what they read from AppKit passed in (`NSScreen.screens`'
/// visible frames, `NSScreen.main`, the saved origin from the defaults, the run's away origin); the rest verbatim.
@MainActor enum MacPetOracle {
    static func defaultPetOrigin(petSize: CGFloat, mainVisible: NSRect?) -> NSPoint {
        guard let visible = mainVisible else { return NSPoint(x: 120, y: 120) }
        return NSPoint(x: visible.maxX - petSize - 24, y: visible.minY + 24)
    }

    static func targetFrame(away: NSPoint?, saved: NSPoint?, petSize: CGFloat, showingBubble: Bool, visibleFrames: [NSRect], mainVisible: NSRect?) -> NSRect {
        let size = FloatingPetController.panelSize(petSize: petSize, showingBubble: showingBubble)
        let petOrigin: NSPoint
        if let awayPetOrigin = away {
            petOrigin = awayPetOrigin
        } else if let saved {
            petOrigin = saved
        } else {
            petOrigin = defaultPetOrigin(petSize: petSize, mainVisible: mainVisible)
        }
        var frame = NSRect(origin: FloatingPetController.panelOrigin(petOrigin: petOrigin, petSize: petSize, panelSize: size),
                           size: size)
        if !visibleFrames.contains(where: { $0.intersects(frame) }) {
            let fallbackPet = defaultPetOrigin(petSize: petSize, mainVisible: mainVisible)
            frame.origin = FloatingPetController.panelOrigin(petOrigin: fallbackPet, petSize: petSize, panelSize: size)
        }
        return frame
    }
}
