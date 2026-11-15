#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

/// The plaza render harness on Windows (stage 6 Task 15): every scene of the shared list (`PlazaCrossHarness.scenes`: the Mac
/// harness's scenes minus `real-sprites`, plus `base-noon` at 1.25x and 1.5x) built by the SAME builders on a `WinPlazaStage`,
/// driven by the Mac harness's rule, drawn through Direct2D on WARP and compared with the Mac's committed render
/// (`Tests/PlazaCrossReference/mac-reference.tar.gz`, extracted by the workflow) by `PlazaCrossCompare`.
///
///  PTB_PLAZA_CROSS_REF=<dir>   the extracted Mac reference (the test skips without it)
///  PTB_PLAZA_RENDER_OUT=<dir>  outputs: `<stem>.png`, `<stem>.tree.txt`, manifest.tsv, report.md/.tsv, summary.txt, worst-N-*.png,
///                              `win-reference/` (this run in the reference format, for `plaza-render-cross.sh --run`)
///  PTB_PLAZA_DEVICE=warp       (set by the workflow) the software adapter
@MainActor
final class WindowsPlazaRenderHarnessTests: XCTestCase {
    /// The captures the Windows harness cannot render yet, with the capability each waits for. A capture of the Mac reference that
    /// the run did not produce must be listed here (stem -> capability) or the test fails; "skipped" is never silent. Empty now:
    /// panels are drawn in the window (Task 10), not in these scenes, and the photos come through the canvas (Task 8).
    static let expectedSkips: [String: String] = [:]

    private func makeDevice() throws -> WinGfxDevice {
        switch WinGfxDevice.make(forceWarp: true) {
        case .success(let d): return d
        case .failure(let e):
            XCTFail("no Direct2D device: \(e)")
            throw e
        }
    }

    private struct Rendered {
        var captures: [PlazaCrossCapture] = []
        var seconds: [String: Double] = [:]
        var skippedPhotos: [String] = []
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func renderAll(device: WinGfxDevice) async throws -> Rendered {
        let pin = PlazaFixtureTime.pin()
        defer { pin.restore() }
        XCTAssertNotNil(PlatformPlaza.tileSheet(), "the tile sheet must load (PTB_PLAZA_RESOURCES), or every scene is plain grass")
        var out = Rendered()
        for scene in PlazaCrossHarness.scenes {
            let started = now()
            let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
            stage.setBackingScale(scene.backing)
            let w = Int((scene.viewport.width * scene.backing).rounded()), h = Int((scene.viewport.height * scene.backing).rounded())
            let surface = try WinGfxSurface.offscreen(device: device, width: w, height: h).get()
            let renderer = WinPlazaRenderer(surface: surface)
            let last = scene.captures.max() ?? 0
            try await PlazaCrossHarness.drive(scene, stage: stage) { frame, setup in
                XCTAssertEqual(renderer.drawIfNeeded(stage: stage, transparent: true), .drawn, "\(scene.name)@\(frame)")
                device.finish()
                let rgba = try XCTUnwrap(surface.readRGBA(), "\(scene.name)@\(frame): no pixels")
                XCTAssertTrue(rgba.contains { $0 != 0 }, "\(scene.name)@\(frame) is all zero")
                XCTAssertEqual(renderer.stats.failedFrames, 0, WinPlazaCodecs.lastError())
                out.captures.append(PlazaCrossCapture(stem: "\(scene.name)@\(frame)", kind: .scene, width: w, height: h, rgba: rgba,
                                                      lines: PlazaCrossDump.lines(of: setup.scene, backing: scene.backing)))
                if frame == last, setup.photo {
                    if let photo = PlazaCrossHarness.photo(of: scene, setup: setup) { out.captures.append(photo) } else { out.skippedPhotos.append("photo-\(scene.name)") }
                }
            }
            out.seconds[scene.name] = now() - started
        }
        return out
    }

    private func digest(_ captures: [PlazaCrossCapture]) -> [String] {
        captures.sorted { $0.stem < $1.stem }.map { "\($0.stem)\t\(PlazaTreeDump.sha256Hex($0.rgba))\t\(PlazaTreeDump.sha256Hex(Array($0.tree.utf8)))" }
    }

    func testWindowsRenderMatchesTheMacReference() async throws {
        guard let refPath = PlazaRenderEnv.value("PTB_PLAZA_CROSS_REF") else { throw XCTSkip("PTB_PLAZA_CROSS_REF not set (the workflow's render job extracts the Mac reference)") }
        let reference = try PlazaCrossReference.Reader(directory: URL(fileURLWithPath: refPath))
        let outDir = PlazaRenderEnv.value("PTB_PLAZA_RENDER_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ptb-plaza-render-win")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let device = try makeDevice()

        let started = now()
        let first = try await renderAll(device: device)
        let firstSeconds = now() - started
        // A/A: a second run of the whole harness gives the same pixels and trees.
        let second = try await renderAll(device: device)
        let total = now() - started
        let a = digest(first.captures), b = digest(second.captures)
        XCTAssertEqual(a, b, "the Windows harness is not deterministic: two runs differ")
        print("WINRENDER: A/A \(a == b ? "identical" : "DIFFERENT") over \(a.count) captures")

        // Outputs first, so a failing compare still leaves everything to look at.
        for c in first.captures {
            let png = PlazaImage(bitmap: PlazaBitmap(width: c.width, height: c.height, bytes: c.rgba))
            if let data = WinPlazaGraphics.shared.encodePNG(png) { try data.write(to: outDir.appendingPathComponent("\(c.stem).png")) }
            if c.kind == .scene { try c.tree.write(to: outDir.appendingPathComponent("\(c.stem).tree.txt"), atomically: true, encoding: .utf8) }
        }
        try (digest(first.captures).joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
        try PlazaCrossReference.write(first.captures, to: outDir.appendingPathComponent("win-reference"))

        let win = Dictionary(uniqueKeysWithValues: first.captures.map { ($0.stem, $0) })
        let stems = win.keys.filter { reference.entries[$0] != nil }.sorted()
        var skipped: [String: String] = [:]
        for s in reference.stems where win[s] == nil {
            skipped[s] = Self.expectedSkips[s] ?? "UNEXPECTED: the Windows run did not render it"
        }
        var skipLines = skipped.sorted { $0.key < $1.key }.map { "\($0.key): skipped: needs \($0.value)" }
        skipLines += PlazaCrossHarness.alwaysSkipped.map { "\($0.name): skipped: needs \($0.needs)" }
        let report = try PlazaCrossReport.run(stems: stems, mac: { try reference.capture($0) }, win: { win[$0]! }, skipped: skipLines, to: outDir)
        let extra = win.keys.filter { reference.entries[$0] == nil }.sorted()

        var timing = String(format: "harness: %.1f s for one pass (%d captures), %.1f s with the A/A pass\n", firstSeconds, first.captures.count, total)
        timing += first.seconds.sorted { $0.key < $1.key }.map { String(format: "%@\t%.2f s", $0.key, $0.value) }.joined(separator: "\n") + "\n"
        try timing.write(to: outDir.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        print(String(format: "WINRENDER: %d captures in %.1f s (%.1f s with A/A); skipped %d: %@", first.captures.count, firstSeconds, total, skipLines.count, skipLines.joined(separator: " | ")))
        print(report.summary)

        XCTAssertEqual(first.skippedPhotos.sorted(), Array(Self.expectedSkips.keys.filter { $0.hasPrefix("photo-") }).sorted(), "photos the Windows canvas could not make")
        XCTAssertEqual(skipped.filter { Self.expectedSkips[$0.key] == nil }.keys.sorted(), [], "captures of the Mac reference the Windows run did not render and nobody listed as skipped")
        XCTAssertEqual(extra, [], "captures the Windows run rendered but the reference lacks (run scripts/plaza-render-cross.sh --write)")
        XCTAssertGreaterThanOrEqual(stems.count, 100, "too few captures were compared")
        XCTAssertTrue(report.results.allSatisfy(\.passed), report.summary)
    }
}
#endif
