import Foundation

/// One grapheme cluster of a text as an engine measured it: where it is (UTF-16), how wide it draws, and what the
/// engine's UAX #14 line-break rules say about it.
struct PlazaBreakCluster: Equatable, Sendable {
    var utf16: Range<Int>
    var width: CGFloat
    var isWhitespace: Bool
    var isNewline: Bool
    /// The engine's UAX #14 opportunity: a line may end after this cluster.
    var canBreakAfter: Bool
    /// The cluster's first scalar is a Hangul syllable or jamo.
    var isHangul: Bool
    /// The cluster's first scalar is a letter, a mark or a number (Unicode general category L, M or N): what TextKit
    /// counts as part of a word when it decides whether the last line is "a single word" (`pushOut`).
    var isWordCharacter: Bool = true
}

/// Greedy line breaking over engine-measured clusters: the two rules the Mac's text stack applies to the same
/// clusters (`Tests/PlazaParityGoldens/breaks.json` pins both against TextKit and CTFramesetter), so a text engine
/// without them (DirectWrite) wraps like the Mac.
enum PlazaLineBreaker {
    enum Rule: Sendable {
        /// TextKit `.standard` (SwiftUI `Text`): a Korean word stays whole (breaks only where there is white space), and
        /// a last line holding one word takes the word before it down (`pushOut`).
        case swiftUIText
        /// CTFramesetter: UAX #14 as the engine reports it, so Hangul breaks between syllables. Known gap: in
        /// `open ( paren` at 12 pt CoreText sometimes ends a line after `( ` (LB14 forbids it) and sometimes does not.
        case coreTextFrame
    }

    /// A run of clusters up to and including a break opportunity.
    private struct Unit {
        var clusters: Range<Int>
        var ink: CGFloat      // width without trailing white space
        var full: CGFloat
        var endsLine: Bool    // a hard line break follows
    }

    /// Line ranges (UTF-16), trailing white space dropped; an empty text is one empty line; a word wider than `width`
    /// breaks between clusters.
    static func lines(_ clusters: [PlazaBreakCluster], width: CGFloat, rule: Rule) -> [Range<Int>] {
        guard !clusters.isEmpty else { return [0..<0] }
        let units = makeUnits(clusters, rule: rule)
        // a line is a cluster range; a unit that is wider than a whole line is cut between clusters
        var lines: [Range<Int>] = []
        var start = 0, used: CGFloat = 0
        for unit in units {
            // white space at the end of a line hangs: a unit of nothing else never starts a new line
            if unit.ink > 0 && start != unit.clusters.lowerBound && used + unit.ink > width {
                lines.append(start..<unit.clusters.lowerBound)
                start = unit.clusters.lowerBound
                used = 0
            }
            if used == 0 && unit.ink > width {
                var w: CGFloat = 0
                for k in unit.clusters {
                    let c = clusters[k]
                    if k > start && !(c.isWhitespace || c.isNewline) && w + c.width > width {
                        lines.append(start..<k)
                        start = k
                        w = 0
                    }
                    w += c.width
                }
                used = w
            } else {
                used += unit.full
            }
            if unit.endsLine {
                lines.append(start..<unit.clusters.upperBound)
                start = unit.clusters.upperBound
                used = 0
            }
        }
        if start < clusters.count || lines.isEmpty { lines.append(start..<clusters.count) }
        let out = lines.map { trimmed($0, clusters) }
        return rule == .swiftUIText ? pushedOut(out, lines: lines, clusters: clusters, units: units, width: width) : out
    }

    private static func trimmed(_ r: Range<Int>, _ clusters: [PlazaBreakCluster]) -> Range<Int> {
        var end = r.upperBound
        while end > r.lowerBound, clusters[end - 1].isWhitespace || clusters[end - 1].isNewline { end -= 1 }
        if end == r.lowerBound {
            let at = r.lowerBound < clusters.count ? clusters[r.lowerBound].utf16.lowerBound : (clusters.last?.utf16.upperBound ?? 0)
            return at..<at
        }
        return clusters[r.lowerBound].utf16.lowerBound..<clusters[end - 1].utf16.upperBound
    }

    private static func makeUnits(_ clusters: [PlazaBreakCluster], rule: Rule) -> [Unit] {
        func allowsBreak(after k: Int) -> Bool {
            let c = clusters[k]
            if c.isNewline || k + 1 >= clusters.count { return true }
            switch rule {
            case .coreTextFrame: return c.canBreakAfter
            case .swiftUIText: return c.canBreakAfter && !(c.isHangul && clusters[k + 1].isHangul)
            }
        }
        var units: [Unit] = []
        var i = 0
        while i < clusters.count {
            var j = i
            while !allowsBreak(after: j) { j += 1 }
            var full: CGFloat = 0, ink: CGFloat = 0
            for k in i...j {
                full += clusters[k].width
                if !(clusters[k].isWhitespace || clusters[k].isNewline) { ink = full }
            }
            units.append(Unit(clusters: i..<(j + 1), ink: ink, full: full, endsLine: clusters[j].isNewline))
            i = j + 1
        }
        return units
    }

    /// TextKit's `pushOut` (`.standard` includes it). Measured on the corpus: it acts only on a paragraph of exactly two
    /// lines, when the second holds a single word made only of letters, marks and numbers (not `effective!!`, `¥100`,
    /// `«x»`, an emoji) and the first holds at least three words; that line's last word then moves down, if the new
    /// last line still fits. Known gap: TextKit also pushes `💧` down in `불꽃 🔥 물 💧 풀 🌿` at 15 pt / 120 pt, where the
    /// last line is a word and an emoji; no emoji rule fitted the rest of the corpus, so it is listed as a gap.
    private static func pushedOut(_ out: [Range<Int>], lines: [Range<Int>], clusters: [PlazaBreakCluster], units: [Unit], width: CGFloat) -> [Range<Int>] {
        guard lines.count == 2 else { return out }
        let last = lines[1], prev = lines[0]
        if clusters[prev.upperBound - 1].isNewline { return out }
        func inkUnits(_ line: Range<Int>) -> [Unit] {
            units.filter { line.contains($0.clusters.lowerBound) && $0.clusters.upperBound <= line.upperBound && $0.ink > 0 }
        }
        let lastUnits = inkUnits(last), prevUnits = inkUnits(prev)
        guard lastUnits.count == 1, prevUnits.count >= 3 else { return out }
        guard clusters[last].allSatisfy({ $0.isWhitespace || $0.isNewline || $0.isWordCharacter }) else { return out }
        let moved = prevUnits[prevUnits.count - 1]
        guard moved.ink + clusters[moved.clusters.upperBound..<last.lowerBound].reduce(0, { $0 + $1.width }) + lastUnits[0].ink <= width else { return out }
        var result = out
        result[0] = trimmed(prev.lowerBound..<moved.clusters.lowerBound, clusters)
        result[1] = trimmed(moved.clusters.lowerBound..<last.upperBound, clusters)
        return result
    }
}
