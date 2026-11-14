import AppKit
import XCTest
@testable import PokeTokenBar

/// Offscreen plaza render harness entry points (Mac only). See `scripts/plaza-render-compare.sh`.
@MainActor
final class PlazaRenderCompareTests: XCTestCase {
    /// Renders every scene of `PlazaRenderScenes.all` into `PTB_PLAZA_RENDER_OUT`.
    func testRenderAllScenes() throws {
        guard let out = PlazaRenderEnv.value("PTB_PLAZA_RENDER_OUT") else { throw XCTSkip("PTB_PLAZA_RENDER_OUT not set") }
        let dir = URL(fileURLWithPath: out)
        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        XCTAssertNotNil(PlazaResources.tileSheet(), "the tile sheet must load, or every scene falls back to plain grass")
        if PlazaRenderScenes.spritesDir == nil { print("PLAZA-RENDER: real-sprites skipped (PTB_PLAZA_RENDER_SPRITES not set or no cached GIFs)") }
        var all: [PlazaRenderCapture] = []
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scene in PlazaRenderScenes.all {
            let (captures, photo) = PlazaRenderRun.run(scene, renderer: renderer)
            // in-process A/A: the same scene built and rendered a second time must be byte-identical
            let (again, photoAgain) = PlazaRenderRun.run(scene, renderer: renderer)
            for (x, y) in zip(captures, again) where x.bgra != y.bgra || x.tree != y.tree {
                try? PlazaRenderRun.write(again.filter { $0.frame == y.frame }, to: dir.appendingPathComponent("aa-second"))
                XCTFail("in-process A/A differs: \(x.scene)@\(x.frame) pixels \(x.bgra != y.bgra) tree \(x.tree != y.tree)")
            }
            XCTAssertEqual(photo?.rgbaSHA256, photoAgain?.rgbaSHA256, "in-process A/A photo \(scene.name)")
            XCTAssertEqual(captures.count, scene.captures.count, scene.name)
            for c in captures where !c.bgra.contains(where: { $0 != 0 }) { XCTFail("\(c.scene)@\(c.frame) is all zero (black/empty)") }
            for c in captures where !c.parity.isEmpty { XCTFail("\(c.scene)@\(c.frame): shared tree and SpriteKit differ:\n" + c.parity.prefix(5).joined(separator: "\n")) }
            try PlazaRenderRun.write(captures, to: dir)
            if let photo {
                try photo.png.write(to: dir.appendingPathComponent("photo-\(scene.name).png"))
                try (photo.rgbaSHA256 + "\n").write(to: dir.appendingPathComponent("photo-\(scene.name).rgba.sha256"), atomically: true, encoding: .utf8)
            }
            all += captures
        }
        try PlazaRenderRun.manifest(all).write(to: dir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
        try PlazaRenderRun.tieReport(all).write(to: dir.appendingPathComponent("ties.txt"), atomically: true, encoding: .utf8)
    }

    private struct Row { let scene: String, frame: Int, bgra: String, tree: String }

    private func manifest(_ dir: URL) throws -> [String: Row] {
        let text = try String(contentsOf: dir.appendingPathComponent("manifest.tsv"), encoding: .utf8)
        var rows: [String: Row] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let frame = Int(f[1]) else { continue }
            rows["\(f[0])@\(f[1])"] = Row(scene: f[0], frame: frame, bgra: f[2], tree: f[3])
        }
        return rows
    }

    private func photos(_ dir: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: String] = [:]
        for n in names where n.hasPrefix("photo-") && n.hasSuffix(".rgba.sha256") {
            out[n] = (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// Compares two render directories; writes `compare-result.txt` and `diff-*.png` into B.
    func testRendersMatch() throws {
        guard let a = PlazaRenderEnv.value("PTB_PLAZA_RENDER_A"), let b = PlazaRenderEnv.value("PTB_PLAZA_RENDER_B") else {
            throw XCTSkip("PTB_PLAZA_RENDER_A / _B not set")
        }
        let dirA = URL(fileURLWithPath: a), dirB = URL(fileURLWithPath: b)
        let ma = try manifest(dirA), mb = try manifest(dirB)
        var differ: [String] = []
        var report: [String] = []
        for key in Set(ma.keys).union(mb.keys).sorted() {
            guard let ra = ma[key], let rb = mb[key] else {
                differ.append(key); report.append("\(key): present in only one side"); continue
            }
            let pixelsDiffer = ra.bgra != rb.bgra, treeDiffers = ra.tree != rb.tree
            guard pixelsDiffer || treeDiffers else { continue }
            differ.append(key)
            if pixelsDiffer { report.append(describePixels(key, dirA, dirB)) } else { report.append("\(key): pixels identical, node tree differs") }
            if treeDiffers { report.append(treeDiff(key, dirA, dirB)) }
        }
        let pa = photos(dirA), pb = photos(dirB)
        for key in Set(pa.keys).union(pb.keys).sorted() where pa[key] != pb[key] {
            differ.append(key.replacingOccurrences(of: ".rgba.sha256", with: "")); report.append("\(key): photo bytes differ")
        }
        let summary = differ.isEmpty ? "RENDER: identical (\(ma.count) captures, \(pa.count) photos)" : "RENDER: \(differ.count) differ: \(differ.joined(separator: " "))"
        try ([summary] + report).joined(separator: "\n").appending("\n").write(to: dirB.appendingPathComponent("compare-result.txt"), atomically: true, encoding: .utf8)
        print(summary)
        for line in report { print(line) }
        XCTAssertTrue(differ.isEmpty, summary)
    }

    private func describePixels(_ key: String, _ a: URL, _ b: URL) -> String {
        guard let da = try? Data(contentsOf: a.appendingPathComponent("\(key).bgra")), let db = try? Data(contentsOf: b.appendingPathComponent("\(key).bgra")),
              da.count == db.count, da.count > 0 else { return "\(key): pixels differ (size mismatch or unreadable)" }
        let pxCount = da.count / 4
        let width = Int((Double(pxCount) * 4.0 / 3.0).squareRoot())   // 640x480 = 4:3
        var diff = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var mask = [UInt8](repeating: 0, count: da.count)
        let w = width > 0 && pxCount % width == 0 ? width : 640
        for i in 0..<pxCount where !(da[i * 4] == db[i * 4] && da[i * 4 + 1] == db[i * 4 + 1] && da[i * 4 + 2] == db[i * 4 + 2] && da[i * 4 + 3] == db[i * 4 + 3]) {
            diff += 1
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            mask[i * 4] = 255; mask[i * 4 + 1] = 0; mask[i * 4 + 2] = 255; mask[i * 4 + 3] = 255   // magenta (BGRA)
        }
        if diff > 0, let png = PlazaRenderRun.png(bgra: mask, width: w, height: pxCount / w) { try? png.write(to: b.appendingPathComponent("diff-\(key).png")) }
        return "\(key): \(diff) px differ, bbox x \(minX)...\(maxX) y \(minY)...\(maxY)"
    }

    private func treeDiff(_ key: String, _ a: URL, _ b: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        p.arguments = ["-u", a.appendingPathComponent("\(key).tree.txt").path, b.appendingPathComponent("\(key).tree.txt").path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(40).joined(separator: "\n")
        return "\(key) tree diff:\n\(text)"
    }
}
