import Foundation
@testable import PokeTokenBar

/// The cross-OS comparer (stage 6 Task 15): one Mac capture against the Windows capture of the same scene frame (or photo).
///
/// Three levels, each reported per capture:
///  1. Tree: every node line equal, except the text-derived differences listed below, each printed with its reason. Any other
///     difference fails.
///       a. a `.canvasWithText` texture (name plate, bubble, emote, wet mark, timer text...): its size (`size=` and the
///          texture's `WxH`) and its pixel hash differ (the two OSes lay text out with their own fonts);
///       b. a node's position `p=`, when its sibling window (the actor's plate, emote and wet mark are consecutive siblings of
///          the camera) holds a text node whose size changed by D points: the position may move by up to D + 1 points;
///       c. a `.canvas` texture without text: its pixel hash may differ (a canvas is drawn by CoreGraphics on one OS and by
///          Direct2D on the other), never its size.
///  2. Scene pixels outside the rectangles of every node that has a difference of class a or b (both OSes' rectangles, grown by
///     2 pixels): every channel within `tolerance` (3); at most 0.1 % of those pixels may be above it. The worst pixel is reported.
///  3. The full frame including text: the count of differing pixels, reported, and a loose gate (pixels above the tolerance, text included, at most 35 % of the frame).
///
/// Photos have no tree: the masks are the plates' and bubbles' rectangles; level 2 and 3 are the same.
enum PlazaCrossCompare {
    static let tolerance = 3
    static let overFraction = 0.001
    static let looseFullFrameFraction = 0.35
    static let maskGrow = 2

    /// SpriteKit has no fractional display scale, so the Mac's render at 1.25x / 1.5x is an arbitrary viewport, not a display it
    /// ever drives: single-texel flips on sprite edges (measured: 0.08 % to 0.11 % of the frame, see the PR images) are allowed
    /// up to this fraction there instead of `overFraction`.
    static let fractionalOverFraction = 0.005
    static func overFraction(for stem: String) -> Double { stem.contains("x@") && (stem.contains("1.25x") || stem.contains("1.5x")) ? fractionalOverFraction : overFraction }

    /// Captures whose failure is a Windows renderer defect found by this harness and not yet fixed (stem -> what is wrong). They
    /// are reported as `known` and do not fail the job; a listed capture that starts passing fails the test until it is
    /// removed here, so the list cannot rot.
    static var knownRendererBugs: [String: String] = [:]

    struct Allowed {
        let cls: Character
        let line: Int
        let reason: String
    }

    struct PixelStats {
        var sizeMismatch = false
        var outside = 0
        var over = 0
        var maxDiff = 0
        var worst: (x: Int, y: Int, mac: [UInt8], win: [UInt8])?
        var differingAll = 0
        /// Pixels above the tolerance anywhere in the frame, text rectangles included.
        var overAll = 0
        var maskedArea = 0
        var differingMasked = 0
        var total = 0
    }

    struct Result {
        var stem: String
        var kind: PlazaCrossCapture.Kind
        var treeFailures: [String] = []
        var allowed: [Allowed] = []
        var pixels = PixelStats()
        var masks: [PlazaCrossRect] = []

        var treeState: String {
            if !treeFailures.isEmpty { return "DIFF(\(treeFailures.count))" }
            return allowed.isEmpty ? "same" : "allowed(\(allowed.count))"
        }
        var pixelsPass: Bool { !pixels.sizeMismatch && Double(pixels.over) <= Double(pixels.outside) * PlazaCrossCompare.overFraction(for: stem) }
        var known: String? { PlazaCrossCompare.knownRendererBugs[stem] }
        /// Passed, or failed as a listed known renderer bug (which must fail: a fixed one is listed no longer).
        var acceptable: Bool { known == nil ? passed : !passed }
        var loosePass: Bool { !pixels.sizeMismatch && Double(pixels.overAll) <= Double(pixels.total) * looseFullFrameFraction }
        var passed: Bool { treeFailures.isEmpty && pixelsPass && loosePass }
        /// Sort key for the "worst five": the pixels above tolerance outside the masks first, then the largest difference.
        var badness: (Int, Int, Int) { (treeFailures.count, pixels.over, pixels.maxDiff) }
    }

    // MARK: Entry

    static func compare(mac: PlazaCrossCapture, win: PlazaCrossCapture) -> Result {
        var result = Result(stem: mac.stem, kind: mac.kind)
        var maskRects: [PlazaCrossRect] = []
        if mac.kind == .scene {
            compareTrees(mac: mac.lines, win: win.lines, into: &result, masks: &maskRects)
        } else {
            maskRects = mac.photoRects + win.photoRects
            if mac.photoRects.count != win.photoRects.count { result.treeFailures.append("photo: \(mac.photoRects.count) text rectangles on the Mac, \(win.photoRects.count) on Windows") }
        }
        result.masks = maskRects.map { $0.dilated(maskGrow) }
        result.pixels = comparePixels(mac: mac, win: win, masks: result.masks)
        return result
    }

    // MARK: Level 1: trees

    private struct Parsed {
        let depth: Int
        let tokens: [Substring]
        init(_ text: String) {
            depth = text.prefix { $0 == " " }.count
            tokens = text.dropFirst(depth).split(separator: " ", omittingEmptySubsequences: true)
        }
    }

    private static func key(_ token: Substring) -> String {
        if token.hasPrefix("tex"), token.contains(":") { return "tex" }
        if let eq = token.firstIndex(of: "=") { return String(token[..<eq]) }
        return "class"
    }

    private static func pair(_ token: Substring) -> (CGFloat, CGFloat)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let p = token[token.index(after: eq)...].split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
    }

    private static func sizeOf(_ token: Substring) -> (CGFloat, CGFloat)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let p = token[token.index(after: eq)...].split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
    }

    /// `tex<n>:<w>x<h>#<hash>` -> (`tex<n>`, `<w>x<h>`, hash)
    private static func textureParts(_ token: Substring) -> (ordinal: Substring, size: Substring, hash: Substring)? {
        guard let colon = token.firstIndex(of: ":"), let hash = token.firstIndex(of: "#") else {
            guard let colon = token.firstIndex(of: ":") else { return nil }
            return (token[..<colon], token[token.index(after: colon)...], "")
        }
        return (token[..<colon], token[token.index(after: colon)..<hash], token[token.index(after: hash)...])
    }

    private static func compareTrees(mac: [PlazaCrossLine], win: [PlazaCrossLine], into result: inout Result, masks: inout [PlazaCrossRect]) {
        guard mac.count == win.count else {
            result.treeFailures.append("node count: \(mac.count) on the Mac, \(win.count) on Windows" + firstDivergence(mac, win))
            return
        }
        let parsedMac = mac.map { Parsed($0.text) }, parsedWin = win.map { Parsed($0.text) }
        // Sibling structure from the depths.
        var parent = [Int](repeating: -1, count: mac.count)
        var siblings: [Int: [Int]] = [:]
        var stack: [Int] = []
        for i in 0..<mac.count {
            let d = parsedMac[i].depth
            while stack.count > d { stack.removeLast() }
            parent[i] = stack.last ?? -1
            siblings[parent[i], default: []].append(i)
            stack.append(i)
        }
        // Text size deltas (class a) per node.
        var delta = [CGFloat](repeating: 0, count: mac.count)
        for i in 0..<mac.count where mac[i].origin == "t" && win[i].origin == "t" && mac[i].text != win[i].text {
            let a = parsedMac[i].tokens, b = parsedWin[i].tokens
            guard a.count == b.count, let k = a.firstIndex(where: { key($0) == "size" }), let s1 = sizeOf(a[k]), let s2 = sizeOf(b[k]) else { continue }
            delta[i] = max(abs(s1.0 - s2.0), abs(s1.1 - s2.1))
        }
        var position = [Int](repeating: 0, count: mac.count)
        for (_, list) in siblings { for (n, i) in list.enumerated() { position[i] = n } }
        func windowDelta(_ i: Int) -> CGFloat {
            guard let list = siblings[parent[i]] else { return delta[i] }
            let n = position[i]
            return list[max(0, n - 2)...min(list.count - 1, n + 2)].map { delta[$0] }.max() ?? 0
        }

        for i in 0..<mac.count {
            let m = mac[i], w = win[i]
            if m.origin != w.origin {
                result.treeFailures.append("line \(i + 1): texture origin \(m.origin) on the Mac, \(w.origin) on Windows\n    mac: \(m.text)\n    win: \(w.text)")
                continue
            }
            if m.text == w.text { continue }
            let a = parsedMac[i], b = parsedWin[i]
            guard a.depth == b.depth, a.tokens.count == b.tokens.count else {
                result.treeFailures.append("line \(i + 1): the node line changed shape\n    mac: \(m.text)\n    win: \(w.text)")
                continue
            }
            let pIndex = a.tokens.firstIndex { key($0) == "p" }
            var failed: [String] = []
            var allowed: [Allowed] = []
            for k in 0..<a.tokens.count where a.tokens[k] != b.tokens[k] {
                let name = key(a.tokens[k])
                if name == "p" {
                    guard k == pIndex, let p1 = pair(a.tokens[k]), let p2 = pair(b.tokens[k]) else { failed.append("p (mask): \(a.tokens[k]) vs \(b.tokens[k])"); continue }
                    let moved = max(abs(p1.0 - p2.0), abs(p1.1 - p2.1))
                    let bound = windowDelta(i) + 1
                    if moved <= bound {
                        allowed.append(Allowed(cls: "b", line: i + 1, reason: "b: position \(p1.0),\(p1.1) -> \(p2.0),\(p2.1) (moved \(fmt(moved)) <= text delta \(fmt(windowDelta(i))) + 1)"))
                    } else {
                        failed.append("p moved \(fmt(moved)) pt, more than the text delta \(fmt(windowDelta(i))) + 1")
                    }
                    continue
                }
                switch name {
                case "size":
                    if m.origin == "t" { allowed.append(Allowed(cls: "a", line: i + 1, reason: "a: text size \(a.tokens[k].dropFirst(5)) -> \(b.tokens[k].dropFirst(5))")) } else { failed.append("size: \(a.tokens[k]) vs \(b.tokens[k])") }
                case "tex":
                    guard let x = textureParts(a.tokens[k]), let y = textureParts(b.tokens[k]) else { failed.append("texture token"); continue }
                    if x.ordinal != y.ordinal { failed.append("texture ordinal \(x.ordinal) vs \(y.ordinal)"); continue }
                    switch m.origin {
                    case "t": allowed.append(Allowed(cls: "a", line: i + 1, reason: "a: text texture \(x.size)#\(x.hash.prefix(6)) -> \(y.size)#\(y.hash.prefix(6))"))
                    case "c":
                        if x.size == y.size { allowed.append(Allowed(cls: "c", line: i + 1, reason: "c: canvas hash \(x.hash.prefix(6)) -> \(y.hash.prefix(6)) (size \(x.size))")) } else { failed.append("canvas size \(x.size) vs \(y.size)") }
                    default: failed.append("pixel texture differs: \(a.tokens[k]) vs \(b.tokens[k])")
                    }
                default:
                    failed.append("\(name): \(a.tokens[k]) vs \(b.tokens[k])")
                }
            }
            if !failed.isEmpty {
                result.treeFailures.append("line \(i + 1): " + failed.joined(separator: "; ") + "\n    mac: \(m.text)\n    win: \(w.text)")
            }
            result.allowed += allowed
            if allowed.contains(where: { $0.cls == "a" || $0.cls == "b" }) {
                if let r = m.rect { masks.append(r) }
                if let r = w.rect { masks.append(r) }
            }
        }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    private static func firstDivergence(_ mac: [PlazaCrossLine], _ win: [PlazaCrossLine]) -> String {
        for i in 0..<min(mac.count, win.count) where mac[i].text != win[i].text {
            return "; first differing line \(i + 1)\n    mac: \(mac[i].text)\n    win: \(win[i].text)"
        }
        return ""
    }

    // MARK: Levels 2 and 3: pixels

    static func comparePixels(mac: PlazaCrossCapture, win: PlazaCrossCapture, masks: [PlazaCrossRect]) -> PixelStats {
        var s = PixelStats()
        guard mac.width == win.width, mac.height == win.height, mac.rgba.count == win.rgba.count, mac.rgba.count == mac.width * mac.height * 4 else {
            s.sizeMismatch = true
            return s
        }
        let w = mac.width, h = mac.height
        s.total = w * h
        var mask = [UInt8](repeating: 0, count: w * h)
        for r in masks {
            let x0 = max(0, r.l), x1 = min(w, r.r), y0 = max(0, r.t), y1 = min(h, r.b)
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = 1 } }
        }
        s.maskedArea = mask.reduce(0) { $0 + Int($1) }
        s.outside = s.total - s.maskedArea
        mac.rgba.withUnsafeBufferPointer { a in
            win.rgba.withUnsafeBufferPointer { b in
                mask.withUnsafeBufferPointer { m in
                    for y in 0..<h {
                        let row = y * w * 4
                        if memcmp(a.baseAddress! + row, b.baseAddress! + row, w * 4) == 0 { continue }
                        for x in 0..<w {
                            let i = row + x * 4
                            let d0 = abs(Int(a[i]) - Int(b[i])), d1 = abs(Int(a[i + 1]) - Int(b[i + 1]))
                            let d2 = abs(Int(a[i + 2]) - Int(b[i + 2])), d3 = abs(Int(a[i + 3]) - Int(b[i + 3]))
                            let d = max(max(d0, d1), max(d2, d3))
                            guard d > 0 else { continue }
                            s.differingAll += 1
                            if d > tolerance { s.overAll += 1 }
                            if m[y * w + x] != 0 { s.differingMasked += 1; continue }
                            if d > tolerance { s.over += 1 }
                            if d > s.maxDiff {
                                s.maxDiff = d
                                s.worst = (x, y, [a[i], a[i + 1], a[i + 2], a[i + 3]], [b[i], b[i + 1], b[i + 2], b[i + 3]])
                            }
                        }
                    }
                }
            }
        }
        return s
    }

    // MARK: Report

    static func table(_ results: [Result], skipped: [String] = []) -> String {
        var lines = ["| capture | tree | allowed a/b/c | masked-out px | max diff outside | px over \(tolerance) | worst pixel (x,y mac -> win) | full frame px differing (over \(tolerance)) | verdict |",
                     "|---|---|---|---|---|---|---|---|---|"]
        for r in results.sorted(by: { $0.stem < $1.stem }) {
            let a = r.allowed.filter { $0.cls == "a" }.count, b = r.allowed.filter { $0.cls == "b" }.count, c = r.allowed.filter { $0.cls == "c" }.count
            let worst = r.pixels.worst.map { "\($0.x),\($0.y) \($0.mac) -> \($0.win)" } ?? "-"
            let px = r.pixels
            lines.append("| \(r.stem) | \(r.treeState) | \(a)/\(b)/\(c) | \(px.maskedArea) | \(px.sizeMismatch ? "size!" : "\(px.maxDiff)") | \(px.over)/\(px.outside) | \(worst) | \(px.differingAll) (\(px.overAll))/\(px.total) | \(r.passed ? "ok" : (r.known != nil ? "KNOWN BUG" : "FAIL")) |")
        }
        for s in skipped { lines.append("| \(s) | | | | | | | | skipped |") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line a script can grep: `CROSS: ok (<n> captures, <m> allowed differences)` or the failures.
    static func summary(_ results: [Result]) -> String {
        let failed = results.filter { !$0.acceptable }
        let allowed = results.reduce(0) { $0 + $1.allowed.count }
        let known = results.filter { $0.known != nil && !$0.passed }.map(\.stem)
        if failed.isEmpty { return "CROSS: ok (\(results.count) captures, \(allowed) allowed differences" + (known.isEmpty ? ")" : "; \(known.count) known renderer bugs: \(known.joined(separator: " ")))") }
        let why = failed.prefix(40).map { r -> String in
            var reasons: [String] = r.known != nil && r.passed ? ["listed as a known renderer bug but passes: remove it from knownRendererBugs"] : []
            if !r.treeFailures.isEmpty { reasons.append("tree \(r.treeFailures.count)") }
            if !r.pixelsPass { reasons.append(r.pixels.sizeMismatch ? "size" : "pixels \(r.pixels.over) over \(tolerance) (max \(r.pixels.maxDiff))") }
            if !r.loosePass { reasons.append("full frame \(r.pixels.overAll)/\(r.pixels.total) over \(tolerance)") }
            return "\(r.stem) \(reasons.joined(separator: ", "))"
        }
        return "CROSS: \(failed.count) fail: " + why.joined(separator: "; ")
    }

    /// Allowed differences, grouped per class with one example each, for the PR body.
    static func allowedSummary(_ results: [Result]) -> String {
        var out: [String] = []
        for cls: Character in ["a", "b", "c"] {
            let hits = results.flatMap { r in r.allowed.filter { $0.cls == cls }.map { (r.stem, $0) } }
            let scenes = Set(hits.map { String($0.0.split(separator: "@").first ?? "") })
            out.append("class \(cls): \(hits.count) differences in \(scenes.count) scenes" + (hits.first.map { "; e.g. \($0.0) line \($0.1.line): \($0.1.reason)" } ?? ""))
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Side by side

    /// Mac | Windows | difference (grey: any difference, x8; red: above tolerance outside the masks; blue frame: a mask),
    /// as one premultiplied RGBA bitmap.
    static func sideBySide(mac: PlazaCrossCapture, win: PlazaCrossCapture, masks: [PlazaCrossRect]) -> PlazaBitmap? {
        guard mac.width == win.width, mac.height == win.height else { return nil }
        let w = mac.width, h = mac.height
        var out = PlazaBitmap(width: w * 3 + 8, height: h)
        let stride = out.width * 4
        var inMask = [Bool](repeating: false, count: w * h)
        for r in masks {
            let x0 = max(0, r.l), x1 = min(w, r.r), y0 = max(0, r.t), y1 = min(h, r.b)
            guard x1 > x0, y1 > y0 else { continue }   // a rectangle off the frame (a plate beyond the edge)
            for y in y0..<y1 { for x in x0..<x1 { inMask[y * w + x] = true } }
        }
        out.bytes.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    for c in 0..<4 {
                        o[y * stride + x * 4 + c] = mac.rgba[i + c]
                        o[y * stride + (w + 4 + x) * 4 + c] = win.rgba[i + c]
                    }
                    let d = (0..<4).map { abs(Int(mac.rgba[i + $0]) - Int(win.rgba[i + $0])) }.max() ?? 0
                    let px = y * stride + (2 * w + 8 + x) * 4
                    var rgb: (UInt8, UInt8, UInt8) = (0, 0, 0)
                    if d > 0 {
                        let g = UInt8(min(255, 40 + d * 8))
                        rgb = (g, g, g)
                        if inMask[y * w + x] { rgb = (0, 0, g) } else if d > tolerance { rgb = (255, 0, 0) }
                    } else if inMask[y * w + x] {
                        rgb = (0, 0, 60)
                    }
                    o[px] = rgb.0; o[px + 1] = rgb.1; o[px + 2] = rgb.2; o[px + 3] = 255
                }
            }
            for y in 0..<h { for x in w..<(w + 4) { for c in 0..<4 { o[y * stride + x * 4 + c] = 255; o[y * stride + (x + w + 4) * 4 + c] = 255 } } }
        }
        return out
    }
}
