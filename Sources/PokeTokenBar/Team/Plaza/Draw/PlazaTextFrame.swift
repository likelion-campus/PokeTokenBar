import Foundation

/// CoreText's frame layout (`CTFramesetter` / `CTFrame`), measured on the Mac (stage 6, Task 9), so a text engine without
/// frames (DirectWrite) lays a paragraph out as the Mac does. Fed the same clusters as `PlazaLineBreaker`, plus each
/// cluster's font metrics. Pinned by `PlazaTextFrameTests` (the Galmuri corpus of `breaks.json`, both OSes) and
/// `PlazaTextFrameMacTests` (live CTFramesetter, fallback fonts included):
/// - lines: `PlazaLineBreaker.lines(_:width:rule: .coreTextFrame)`; an empty text has none;
/// - a line's ascent, descent and leading are the largest of its clusters' (the white space it swallowed included). Known
///   gap (Mac only, pinned in `PlazaTextFrameTests+Mac`): a line drawn wholly in Helvetica, CoreText's fallback for
///   Cyrillic and Greek in Galmuri14, steps by Galmuri14's ascent instead of Helvetica's (lines wholly in Geeza Pro, Lucida
///   Grande or Apple Color Emoji take their own); no rule over the fonts explained it, and Windows never falls back to it;
/// - baselines, from the frame's top: the first at round(ascent), each next one round(descent + leading) + round(ascent)
///   below the one before (CoreText rounds each step, not the sum);
/// - a line is in a frame when its baseline + descent is within the frame's height; the lines after the first that is not
///   are not either;
/// - suggested size: the widest line (trailing white space left out) by ceil(baseline + descent) of the last line that
///   fits the limit; an empty text is zero;
/// - visible length: where the first line that is not in the frame begins, or the whole text;
/// - a line is centred on its width without trailing white space, unrounded; natural alignment is flush left, or flush
///   right in a right-to-left paragraph.
enum PlazaTextFrame {
    struct Line: Equatable, Sendable {
        /// UTF-16, trailing white space dropped (`PlazaLineBreaker`'s range).
        var range: Range<Int>
        /// The UTF-16 end of everything the line holds, the white space it swallowed included: where the next line begins.
        var end: Int
        /// Without trailing white space.
        var width: CGFloat
        var ascent: CGFloat, descent: CGFloat, leading: CGFloat
        /// The baseline's distance from the frame's top.
        var baseline: CGFloat
        var bottom: CGFloat { baseline + descent }
    }

    /// `metrics[i]` is the font metrics of `clusters[i]`'s font (descender negative, as `PlazaFontMetrics`).
    static func lines(_ clusters: [PlazaBreakCluster], metrics: [PlazaFontMetrics], width: CGFloat) -> [Line] {
        guard !clusters.isEmpty else { return [] }
        precondition(metrics.count == clusters.count, "one metrics entry per cluster")
        let ranges = PlazaLineBreaker.lines(clusters, width: width, rule: .coreTextFrame)
        var out: [Line] = []
        var i = 0
        for (k, r) in ranges.enumerated() {
            let end = k + 1 < ranges.count ? ranges[k + 1].lowerBound : clusters[clusters.count - 1].utf16.upperBound
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0, w: CGFloat = 0
            while i < clusters.count, clusters[i].utf16.lowerBound < end {
                let m = metrics[i]
                ascent = max(ascent, m.ascender)
                descent = max(descent, -m.descender)
                leading = max(leading, m.leading)
                if clusters[i].utf16.upperBound <= r.upperBound { w += clusters[i].width }
                i += 1
            }
            let baseline: CGFloat
            if let previous = out.last {
                baseline = previous.baseline + (previous.descent + previous.leading).rounded() + ascent.rounded()
            } else {
                baseline = ascent.rounded()
            }
            out.append(Line(range: r, end: end, width: w, ascent: ascent, descent: descent, leading: leading, baseline: baseline))
        }
        return out
    }

    /// The lines that are in a frame `height` tall.
    static func fitting(_ lines: [Line], height: CGFloat) -> ArraySlice<Line> {
        lines.prefix { $0.bottom <= height }
    }

    /// `CTFramesetterSuggestFrameSizeWithConstraints` for `lines` (laid out at the limit's width).
    static func suggestedSize(_ lines: [Line], limit: CGSize) -> CGSize {
        let fit = fitting(lines, height: limit.height)
        guard let last = fit.last else { return .zero }
        return CGSize(width: fit.map(\.width).max() ?? 0, height: last.bottom.rounded(.up))
    }

    /// `CTFrameGetVisibleStringRange(…).length` for `lines` (laid out at the frame's width) in a frame `height` tall.
    static func visibleLength(_ lines: [Line], height: CGFloat, textLength: Int) -> Int {
        let n = fitting(lines, height: height).count
        return n == lines.count ? textLength : lines[n].range.lowerBound
    }

    /// Where `line` starts in a frame `width` wide.
    static func x(of line: Line, in width: CGFloat, alignment: PlazaTextAlignment, rightToLeft: Bool) -> CGFloat {
        switch alignment {
        case .center: (width - line.width) / 2
        case .natural: rightToLeft ? width - line.width : 0
        }
    }

    /// `CTLineCreateTruncatedLine(line, width, .end, ellipsis)` measured on the Mac: how many of the line's clusters stay
    /// before the ellipsis. nil when `width` is less than the ellipsis's (even for a line that fits); all of them when the
    /// line fits (the line comes back unchanged); else the longest start whose width plus the ellipsis's fits, its
    /// trailing white space dropped (the ellipsis then follows the last kept character).
    static func truncation(_ clusters: [PlazaBreakCluster], width: CGFloat, ellipsisWidth: CGFloat) -> Int? {
        if width < ellipsisWidth { return nil }
        if clusters.reduce(CGFloat(0), { $0 + $1.width }) <= width { return clusters.count }
        var used: CGFloat = 0, kept = 0
        while kept < clusters.count, used + clusters[kept].width + ellipsisWidth <= width {
            used += clusters[kept].width
            kept += 1
        }
        while kept > 0, clusters[kept - 1].isWhitespace || clusters[kept - 1].isNewline { kept -= 1 }
        return kept
    }

    /// The paragraph's base direction, as CoreText takes it: the first strong character decides (a letter of Hebrew,
    /// Arabic, Syriac, Thaana, NKo or their presentation forms is right-to-left, any other letter left-to-right); a text
    /// without a letter is left-to-right.
    static func isRightToLeft(_ text: Substring) -> Bool {
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            let v = s.value
            return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
                || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v)
        }
        return false
    }
}
