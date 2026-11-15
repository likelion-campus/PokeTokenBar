import AppKit
import XCTest
@testable import PokeTokenBar

/// The Mac side of the cross-OS render compare (stage 6 Task 15). Offscreen like every harness test (SKRenderer into a Metal
/// texture; no window). Without its environment variable each test skips, except the tree check, which needs only the
/// committed reference and no GPU. See `scripts/plaza-render-cross.sh`.
///
///  PTB_PLAZA_CROSS_OUT=<dir>     render the cross set twice (A/A) and write it in the reference format (`PlazaCrossReference`)
///  PTB_PLAZA_CROSS_CHECK=<dir>   render the cross set and require it to equal the extracted reference in <dir>, pixel for pixel
///  PTB_PLAZA_CROSS_WIN=<dir>     render the cross set and compare it with a Windows run's `win-reference` directory
///  PTB_PLAZA_CROSS_REPORT=<dir>  where that compare writes its report
@MainActor
final class PlazaCrossRenderCompareMacTests: XCTestCase {
    static var referenceArchive: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/PlazaCrossReference/mac-reference.tar.gz")
    }

    static func renderMacSet() throws -> [PlazaCrossCapture] {
        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        var out: [PlazaCrossCapture] = []
        for scene in PlazaCrossHarness.scenes {
            let (captures, photo) = PlazaRenderRun.run(scene, renderer: renderer)
            for c in captures {
                out.append(PlazaCrossCapture(stem: "\(c.scene)@\(c.frame)", kind: .scene, width: c.width, height: c.height,
                                             rgba: PlazaCrossHarness.rgba(fromBGRA: c.bgra), lines: c.cross))
            }
            if let cross = photo?.cross { out.append(cross) }
        }
        return out
    }

    func testWriteCrossReference() throws {
        guard let out = PlazaRenderEnv.value("PTB_PLAZA_CROSS_OUT") else { throw XCTSkip("PTB_PLAZA_CROSS_OUT not set") }
        let first = try Self.renderMacSet()
        let second = try Self.renderMacSet()
        XCTAssertEqual(first.map(\.stem), second.map(\.stem))
        for (a, b) in zip(first, second) where a.rgba != b.rgba || a.lines != b.lines { XCTFail("A/A: \(a.stem) differs between two renders") }
        XCTAssertFalse(first.isEmpty)
        try PlazaCrossReference.write(first, to: URL(fileURLWithPath: out))
        print("CROSS-MAC: wrote \(first.count) captures (\(first.filter { $0.kind == .photo }.count) photos) to \(out)")
    }

    /// The committed reference is what this Mac renders now (same machine only: GPU output may differ across Macs).
    func testCrossReferenceIsFresh() throws {
        guard let dir = PlazaRenderEnv.value("PTB_PLAZA_CROSS_CHECK") else { throw XCTSkip("PTB_PLAZA_CROSS_CHECK not set") }
        let reader = try PlazaCrossReference.Reader(directory: URL(fileURLWithPath: dir))
        let now = try Self.renderMacSet()
        var stale: [String] = []
        for c in now {
            guard let ref = try? reader.capture(c.stem) else { stale.append("\(c.stem) (not in the reference)"); continue }
            if ref.rgba != c.rgba { stale.append("\(c.stem) pixels") } else if ref.lines != c.lines || ref.photoRects != c.photoRects { stale.append("\(c.stem) tree") }
        }
        for s in Set(reader.stems).subtracting(now.map(\.stem)) { stale.append("\(s) (no longer rendered)") }
        let line = stale.isEmpty ? "CROSS-MAC: reference is current (\(now.count) captures)" : "CROSS-MAC: reference is STALE: " + stale.sorted().joined(separator: ", ")
        print(line)
        XCTAssertTrue(stale.isEmpty, line)
    }

    /// Always on, no GPU: the node trees of the committed reference are what the shared scenes build now. A change to a scene,
    /// the art or the scene code that moves a node makes this fail until `scripts/plaza-render-cross.sh --write` is run.
    func testCommittedReferenceTreesAreCurrent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-cross-ref-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", Self.referenceArchive.path, "-C", dir.path]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0, "cannot extract \(Self.referenceArchive.path)")
        let reader = try PlazaCrossReference.Reader(directory: dir)
        let pin = PlazaFixtureTime.pin()
        defer { pin.restore() }
        var seen = Set<String>(), stale: [String] = []
        for scene in PlazaCrossHarness.scenes {
            await PlazaCrossHarness.drive(scene, stage: PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) { frame, setup in
                let stem = "\(scene.name)@\(frame)"
                seen.insert(stem)
                let lines = PlazaCrossDump.lines(of: setup.scene, backing: scene.backing)
                guard let ref = try? reader.capture(stem) else { stale.append("\(stem) (not in the reference)"); return }
                if ref.lines != lines {
                    let at = zip(ref.lines, lines).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(ref.lines.count, lines.count)
                    stale.append("\(stem) line \(at + 1) of \(lines.count)")
                }
            }
        }
        let sceneStems = Set(reader.entries.values.filter { $0.kind == .scene }.map(\.stem))
        for s in sceneStems.subtracting(seen) { stale.append("\(s) (no longer rendered)") }
        XCTAssertTrue(stale.isEmpty, "the committed cross reference is stale (run scripts/plaza-render-cross.sh --write): " + stale.sorted().prefix(20).joined(separator: ", "))
    }

    /// Compares a Windows run with a fresh Mac render. Prints the `CROSS:` line and writes the report.
    func testCompareWithAWindowsRun() throws {
        guard let win = PlazaRenderEnv.value("PTB_PLAZA_CROSS_WIN") else { throw XCTSkip("PTB_PLAZA_CROSS_WIN not set") }
        let reader = try PlazaCrossReference.Reader(directory: URL(fileURLWithPath: win))
        let mac = Dictionary(uniqueKeysWithValues: try Self.renderMacSet().map { ($0.stem, $0) })
        let stems = mac.keys.filter { reader.entries[$0] != nil }.sorted()
        let skipped = mac.keys.filter { reader.entries[$0] == nil }.sorted().map { "\($0): not rendered by the Windows run" }
        let report = URL(fileURLWithPath: PlazaRenderEnv.value("PTB_PLAZA_CROSS_REPORT") ?? NSTemporaryDirectory()).appendingPathComponent("cross-report")
        let out = try PlazaCrossReport.run(stems: stems, mac: { mac[$0]! }, win: { try reader.capture($0) }, skipped: skipped, to: report)
        print(out.summary)
        print("CROSS: report in \(report.path)")
        XCTAssertTrue(out.results.allSatisfy(\.acceptable), out.summary)
    }
}
