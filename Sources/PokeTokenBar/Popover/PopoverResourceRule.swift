import Foundation

/// The one rule every open/close selftest judges a page's leftovers by (stage 7; the kit, the popover window, the plaza close
/// and the page checks each carried a variant, and a fixed handle budget failed on unrelated head after head).
///
/// Cycles are the counts after each open/close, the FIRST being the warm-up (comctl32 and theme caches, fonts, first-use pools).
///  - GDI and USER objects belong to the page: none may be above the warm-up on ANY later cycle. A later drop is a late
///    release, not a leak. `userSlack` exists for the popover window's USER jitter of one (runner evidence in its check), 0 elsewhere.
///  - Kernel handles belong to the whole process (worker threads, TLS and crypto pools start once): they fail only when they
///    rise on EVERY cycle, warm-up included, which is what a handle leaked per open looks like.
/// Pure and shared so both systems test it; the Windows checks print `summary` (every cycle's numbers).
enum PopoverResourceRule {
    struct Sample: Equatable, Sendable {
        var gdi: Int, user: Int, handles: Int
    }

    struct Verdict: Equatable, Sendable {
        var gdiFlat: Bool
        var userFlat: Bool
        /// Handles rose on every cycle.
        var handlesRose: Bool
        var ok: Bool { gdiFlat && userFlat && !handlesRose }
        var summary: String
    }

    /// `cycles[0]` is the warm-up; at least two samples are needed to judge anything.
    static func judge(_ cycles: [Sample], userSlack: Int = 0) -> Verdict {
        guard cycles.count >= 2, let warm = cycles.first else {
            return Verdict(gdiFlat: false, userFlat: false, handlesRose: false, summary: "fewer than 2 cycles")
        }
        let after = cycles.dropFirst()
        let gdiFlat = after.allSatisfy { $0.gdi <= warm.gdi }
        let userFlat = after.allSatisfy { $0.user <= warm.user + userSlack }
        let handlesRose = zip(cycles, after).allSatisfy { $1.handles > $0.handles }
        let list = cycles.enumerated().map { i, c in "\(i == 0 ? "warm-up" : "#\(i)") gdi=\(c.gdi) user=\(c.user) handles=\(c.handles)" }.joined(separator: " / ")
        return Verdict(gdiFlat: gdiFlat, userFlat: userFlat, handlesRose: handlesRose,
                       summary: "\(list) (GDI not above the warm-up on any cycle=\(gdiFlat); USER not above it\(userSlack > 0 ? " + \(userSlack)" : "")=\(userFlat); "
                                + "handles rose on every cycle=\(handlesRose): only that fails, the process's pools are not the page's)")
    }
}
