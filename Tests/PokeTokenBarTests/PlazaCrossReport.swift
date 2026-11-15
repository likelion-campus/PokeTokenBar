import Foundation
@testable import PokeTokenBar

/// Runs the comparer over a set of captures and writes what a person looks at: `report.md` (the table per capture, the
/// allowed-difference classes with an example each, the skipped captures), `report.tsv`, `summary.txt` (the `CROSS:` line) and
/// side-by-side PNGs (Mac | Windows | difference) of the worst five captures.
@MainActor
enum PlazaCrossReport {
    struct Output {
        var results: [PlazaCrossCompare.Result]
        var summary: String
    }

    static func worstFirst(_ results: [PlazaCrossCompare.Result]) -> [PlazaCrossCompare.Result] {
        results.sorted {
            let a = ($0.treeFailures.count, $0.pixels.over, $0.pixels.maxDiff, $0.pixels.differingAll)
            let b = ($1.treeFailures.count, $1.pixels.over, $1.pixels.maxDiff, $1.pixels.differingAll)
            return a != b ? a > b : $0.stem < $1.stem
        }
    }

    /// `mac` and `win` answer a capture by stem. `stems` are the ones both sides have; `skipped` are listed, not compared.
    static func run(stems: [String], mac: (String) throws -> PlazaCrossCapture, win: (String) throws -> PlazaCrossCapture,
                    skipped: [String], to dir: URL) throws -> Output {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [PlazaCrossCompare.Result] = []
        for stem in stems { results.append(PlazaCrossCompare.compare(mac: try mac(stem), win: try win(stem))) }
        let summary = PlazaCrossCompare.summary(results)
        var md = "# Plaza render: Mac vs Windows\n\n\(summary)\n\n"
        md += "Tolerance: every channel within \(PlazaCrossCompare.tolerance) outside the text rectangles (grown by \(PlazaCrossCompare.maskGrow) px), at most \(PlazaCrossCompare.overFraction * 100)% of those pixels above it.\n\n"
        md += "## Allowed differences\n\n```\n" + PlazaCrossCompare.allowedSummary(results) + "```\n\n"
        md += "## Skipped\n\n" + (skipped.isEmpty ? "none\n" : skipped.map { "- \($0)" }.joined(separator: "\n") + "\n")
        md += "\n## Captures\n\n" + PlazaCrossCompare.table(results)
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            md += "\n## Failures (known renderer bugs are marked)\n\n"
            for r in failed {
                md += "### \(r.stem)\(r.known.map { " (known renderer bug: \($0))" } ?? "")\n\n"
                for f in r.treeFailures.prefix(12) { md += "- tree: \(f.replacingOccurrences(of: "\n", with: "\n  "))\n" }
                if r.treeFailures.count > 12 { md += "- ... \(r.treeFailures.count - 12) more tree failures\n" }
                if !r.pixelsPass { md += "- pixels: \(r.pixels.over) of \(r.pixels.outside) outside the masks above \(PlazaCrossCompare.tolerance), max \(r.pixels.maxDiff)\n" }
                if !r.loosePass { md += "- full frame: \(r.pixels.overAll) of \(r.pixels.total) above \(PlazaCrossCompare.tolerance)\n" }
            }
        }
        try md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        var tsv = "stem\tkind\ttree\tallowed_a\tallowed_b\tallowed_c\tmasked_area\tmax_diff_outside\tover_tolerance\toutside\tfull_differing\tfull_over\ttotal\tverdict\n"
        for r in results.sorted(by: { $0.stem < $1.stem }) {
            let a = r.allowed.filter { $0.cls == "a" }.count, b = r.allowed.filter { $0.cls == "b" }.count, c = r.allowed.filter { $0.cls == "c" }.count
            tsv += "\(r.stem)\t\(r.kind.rawValue)\t\(r.treeState)\t\(a)\t\(b)\t\(c)\t\(r.pixels.maskedArea)\t\(r.pixels.maxDiff)\t\(r.pixels.over)\t\(r.pixels.outside)\t\(r.pixels.differingAll)\t\(r.pixels.overAll)\t\(r.pixels.total)\t\(r.passed ? "ok" : (r.known != nil ? "known" : "FAIL"))\n"
        }
        try tsv.write(to: dir.appendingPathComponent("report.tsv"), atomically: true, encoding: .utf8)
        try (summary + "\n").write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        for (rank, r) in worstFirst(results).prefix(5).enumerated() {
            guard let m = try? mac(r.stem), let w = try? win(r.stem), let sheet = PlazaCrossCompare.sideBySide(mac: m, win: w, masks: r.masks),
                  let png = PlatformPlaza.graphics.encodePNG(PlazaImage(bitmap: sheet)) else { continue }
            try png.write(to: dir.appendingPathComponent("worst-\(rank + 1)-\(r.stem).png"))
        }
        return Output(results: results, summary: summary)
    }
}
