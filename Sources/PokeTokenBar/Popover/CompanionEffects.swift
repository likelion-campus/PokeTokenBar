import Foundation

/// SwiftUI's timing curves as values (stage 7 Task 9, D16): the Mac's header animates with `.easeOut`, `.easeInOut` and
/// `.spring(response:dampingFraction:)`; the Windows header samples the same curves on its clock.
enum PopoverMotion {
    /// A cubic Bézier timing curve from (0,0) to (1,1) through (x1,y1) and (x2,y2), at progress `p` in 0…1.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ p: Double) -> Double {
        let p = min(1, max(0, p))
        func coord(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = p
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if coord(t, x1, x2) < p { lo = t } else { hi = t }
        }
        return coord(t, y1, y2)
    }

    static func easeOut(_ p: Double) -> Double { bezier(0, 0, 0.58, 1, p) }
    static func easeIn(_ p: Double) -> Double { bezier(0.42, 0, 1, 1, p) }
    static func easeInOut(_ p: Double) -> Double { bezier(0.42, 0, 0.58, 1, p) }

    /// SwiftUI's `.spring(response:dampingFraction:)` (mass 1, stiffness (2π/response)², under-damped): the progress from 0
    /// to 1 at `t` seconds, overshoot included. Settled once its envelope is under `epsilon` of the travel.
    struct Spring: Equatable, Sendable {
        var response: Double
        var dampingFraction: Double
        static let epsilon = 0.005

        func value(_ t: Double) -> Double {
            guard t > 0 else { return 0 }
            let w = 2 * Double.pi / response, z = min(0.999, dampingFraction)
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
        }

        var settleTime: Double {
            let w = 2 * Double.pi / response, z = min(0.999, dampingFraction)
            return log(1 / (Self.epsilon * (1 - z * z).squareRoot())) / (z * w)
        }
    }
}

/// How the sprite box looks at one moment of a celebration (the Mac's `@State` of `CompanionHeader`, sampled).
struct CompanionArtEffects: Equatable, Sendable {
    /// An emoji burst (✨, 🎭, the mint's three ✨): its transition's scale and opacity.
    struct Burst: Equatable, Sendable {
        var scale: Double
        var opacity: Double
    }

    /// The "+N XP" capsule: its text, opacity and how far it is moved down (the `.move(edge: .bottom)` transition, 0…1 of
    /// its height).
    struct Candy: Equatable, Sendable {
        var text: String
        var opacity: Double
        var drop: Double
    }

    /// The white flash over the box (0.85 → 0).
    var flash: Double = 0
    /// The sprite and its backdrop (0.6 → 1, spring).
    var scale: Double = 1
    /// Degrees (the egg's wiggle, ±5).
    var rotation: Double = 0
    var shiny: Burst?
    var ditto: Burst?
    var candy: Candy?
    var mint: Burst?

    static let rest = CompanionArtEffects()
}

/// What makes `CompanionHeader`'s one-shot effects consumable: the store's three `consume…` calls.
@MainActor protocol CompanionFeedbackConsuming: AnyObject {
    func consumeCelebration()
    func consumeCandyFeedback()
    func consumeMintFeedback()
}

extension CompanionStore: CompanionFeedbackConsuming {}

/// The header's celebrations with the Mac's timings and its one-shot contract (`playCelebrationIfNeeded`,
/// `showCandyXPIfNeeded`, `showMintIfNeeded`, `syncEggWiggle`; pinned in twins.txt): an effect plays when its sequence
/// number is new to this header and the store still holds it, and the header consumes it as it starts, so it plays once
/// on whichever surface shows it first — a header made later (the popover opened again) finds it consumed. Times are
/// seconds from the effect's start; `effects(at:)` samples them and `nextDue(after:)` says when the picture changes next:
/// every 1/60 s while something moves, the next step of a timed event, the wiggle's next pose, or nil when nothing does.
@MainActor final class CompanionCelebrationDriver {
    static let frameInterval: TimeInterval = 1.0 / 60
    /// The wiggle's half period (the Mac's `.easeInOut(duration: 0.35).repeatForever(autoreverses: true)`), drawn as two poses.
    static let wigglePeriod: TimeInterval = 0.35
    static let wiggleDegrees = 5.0

    private static let flashDuration = 0.8
    private static let pop = PopoverMotion.Spring(response: 0.5, dampingFraction: 0.55)
    private static let burstSpring = PopoverMotion.Spring(response: 0.4, dampingFraction: 0.5)
    private static let candySpring = PopoverMotion.Spring(response: 0.4, dampingFraction: 0.6)
    private static let mintSpring = PopoverMotion.Spring(response: 0.35, dampingFraction: 0.5)
    private static let burstHold = 2.6, burstFade = 0.5
    private static let candyHold = 1.3, candyFade = 0.4
    private static let mintHold = 0.9, mintFade = 0.4

    private(set) var seenSeq = -1
    private(set) var seenCandySeq = -1
    private(set) var seenMintSeq = -1
    private(set) var celebration: (kind: CompanionStore.Celebration, start: Date)?
    private(set) var candy: (amount: Int, start: Date)?
    private(set) var mint: Date?
    private(set) var wiggleStart: Date?
    /// How many effects this header started (the selftest's count).
    private(set) var plays = 0

    /// The Mac's `onAppear` / `onChange` calls on one capture of the store: starts what is new and consumes it.
    @discardableResult
    func poll(_ store: CompanionHeaderInput, consumer: any CompanionFeedbackConsuming, now: Date, animates: Bool = true) -> Bool {
        var started = false
        if let c = store.celebration, store.celebrationSeq != seenSeq {
            seenSeq = store.celebrationSeq
            consumer.consumeCelebration()
            if animates { celebration = (c, now) }
            plays += 1
            started = true
        }
        if store.candyFeedbackAmount > 0, store.candyFeedbackSeq != seenCandySeq {
            seenCandySeq = store.candyFeedbackSeq
            let amount = store.candyFeedbackAmount
            consumer.consumeCandyFeedback()
            if animates { candy = (amount, now) }
            plays += 1
            started = true
        }
        if store.mintFeedbackNature != nil, store.mintFeedbackSeq != seenMintSeq {
            seenMintSeq = store.mintFeedbackSeq
            consumer.consumeMintFeedback()
            if animates { mint = now }
            plays += 1
            started = true
        }
        let imminent = CompanionHeaderBuilder(store: store).eggImminent && animates
        if imminent, wiggleStart == nil { wiggleStart = now } else if !imminent { wiggleStart = nil }
        return started
    }

    /// Ends every effect at once (animation turned off, the header going away).
    func stopAll() {
        celebration = nil
        candy = nil
        mint = nil
        wiggleStart = nil
    }

    /// An appearing burst's spring from `delay`, then its fade from `hold` (the Mac's delayed spring and its `Task.sleep`).
    private static func burst(_ t: Double, delay: Double, spring: PopoverMotion.Spring, hold: Double, fade: Double) -> CompanionArtEffects.Burst? {
        guard t >= delay, t < hold + fade else { return nil }
        if t >= hold {
            let k = 1 - PopoverMotion.easeOut((t - hold) / fade)
            return CompanionArtEffects.Burst(scale: k, opacity: k)
        }
        let v = spring.value(t - delay)
        return CompanionArtEffects.Burst(scale: v, opacity: min(1, max(0, v)))
    }

    func effects(at now: Date) -> CompanionArtEffects {
        var e = CompanionArtEffects.rest
        if let c = celebration {
            let t = now.timeIntervalSince(c.start)
            if t < Self.flashDuration { e.flash = 0.85 * (1 - PopoverMotion.easeOut(t / Self.flashDuration)) }
            e.scale = 0.6 + 0.4 * Self.pop.value(t)
            switch c.kind {
            case .hatch(shiny: true):
                e.shiny = Self.burst(t, delay: 0.3, spring: Self.burstSpring, hold: Self.burstHold, fade: Self.burstFade)
            case .dittoReveal(let shiny):
                e.ditto = Self.burst(t, delay: 0.25, spring: Self.burstSpring, hold: Self.burstHold, fade: Self.burstFade)
                if shiny { e.shiny = Self.burst(t, delay: 0.45, spring: Self.burstSpring, hold: Self.burstHold, fade: Self.burstFade) }
            default: break
            }
        }
        if let c = candy {
            let t = now.timeIntervalSince(c.start)
            let candyXPAmount = c.amount
            let text = "+\(TokenFormatter.compact(candyXPAmount)) XP"
            if t < Self.candyHold {
                let v = Self.candySpring.value(t)
                e.candy = CompanionArtEffects.Candy(text: text, opacity: min(1, max(0, v)), drop: 1 - v)
            } else if t < Self.candyHold + Self.candyFade {
                let k = PopoverMotion.easeOut((t - Self.candyHold) / Self.candyFade)
                e.candy = CompanionArtEffects.Candy(text: text, opacity: 1 - k, drop: k)
            }
        }
        if let m = mint {
            e.mint = Self.burst(now.timeIntervalSince(m), delay: 0, spring: Self.mintSpring, hold: Self.mintHold, fade: Self.mintFade)
        }
        if let w = wiggleStart {
            let step = Int((now.timeIntervalSince(w) + Self.timeSlack) / Self.wigglePeriod)
            e.rotation = step % 2 == 0 ? -Self.wiggleDegrees : Self.wiggleDegrees
        }
        return e
    }

    /// The spans (seconds from the start) in which a celebration's picture moves: the flash and the pop, each burst's spring,
    /// the bursts' fade. Between them it holds still.
    static func movingSpans(_ kind: CompanionStore.Celebration) -> [ClosedRange<Double>] {
        var spans = [0...max(flashDuration, pop.settleTime)]
        let delays: [Double]
        switch kind {
        case .hatch(shiny: true): delays = [0.3]
        case .dittoReveal(let shiny): delays = shiny ? [0.25, 0.45] : [0.25]
        default: delays = []
        }
        if !delays.isEmpty {
            spans += delays.map { $0...($0 + burstSpring.settleTime) }
            spans.append(burstHold...(burstHold + burstFade))
        }
        return spans
    }

    static var candySpans: [ClosedRange<Double>] { [0...candySpring.settleTime, candyHold...(candyHold + candyFade)] }
    static var mintSpans: [ClosedRange<Double>] { [0...mintSpring.settleTime, mintHold...(mintHold + mintFade)] }

    /// The next moment an effect started at `start` changes its picture: the next frame inside a moving span, else the
    /// start of the next span; nil once the last span is over.
    private static func due(_ spans: [ClosedRange<Double>], start: Date, now: Date) -> Date? {
        // A tick armed for a span's start can land a hair before it (`Date` arithmetic rounds): it counts as inside, so the
        // next due is always later than `now` and the clock moves on.
        let t = now.timeIntervalSince(start) + timeSlack
        if spans.contains(where: { $0.lowerBound <= t && t < $0.upperBound }) { return now.addingTimeInterval(frameInterval) }
        return spans.map(\.lowerBound).filter { $0 > t }.min().map { start.addingTimeInterval($0) }
    }

    /// How far before a moment a tick still counts as at it (rounding of `Date` sums).
    static let timeSlack: TimeInterval = 1e-6

    /// When the picture changes next (nil: never by itself). Finished effects are dropped here.
    func nextDue(after now: Date) -> Date? {
        var times: [Date] = []
        if let c = celebration {
            if let d = Self.due(Self.movingSpans(c.kind), start: c.start, now: now) { times.append(d) } else { celebration = nil }
        }
        if let c = candy {
            if let d = Self.due(Self.candySpans, start: c.start, now: now) { times.append(d) } else { candy = nil }
        }
        if let m = mint {
            if let d = Self.due(Self.mintSpans, start: m, now: now) { times.append(d) } else { mint = nil }
        }
        if let w = wiggleStart {
            let step = floor((now.timeIntervalSince(w) + Self.timeSlack) / Self.wigglePeriod) + 1
            times.append(w.addingTimeInterval(step * Self.wigglePeriod))
        }
        return times.min()
    }

    /// Something other than the wiggle is playing (the clock runs at the frame rate for it).
    var isCelebrating: Bool { celebration != nil || candy != nil || mint != nil }
}
