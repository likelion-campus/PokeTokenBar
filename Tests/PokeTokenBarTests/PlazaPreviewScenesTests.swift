import Foundation
import XCTest
@testable import PokeTokenBar

/// The preview scenes (`PlazaPreviewScenes`) on a headless stage, on both OSes. With `PTB_PLAZA_PREVIEW_OUT` set, each
/// capture's shared tree dump is written there as `<scene>@<frame>.tree.txt`, so a Mac run and a Windows run of the same
/// commit can be compared line by line (stage 6 Task 4; Task 15 turns this into the cross-OS compare).
@MainActor
final class PlazaPreviewScenesTests: XCTestCase {
    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PTB_PLAZA_PREVIEW_OUT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testPreviewScenesBuildAndDumpTheirTrees() async throws {
        let out = Self.outputDirectory
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for scene in PlazaPreviewScenes.all + [PlazaPreviewScenes.rushHour] {
            var dumps: [Int: String] = [:]
            await PlazaPreviewScenes.run(scene, stage: PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) { frame, setup in
                dumps[frame] = PlazaPreviewScenes.dump(setup)
            }
            XCTAssertEqual(dumps.keys.sorted(), scene.captures, scene.name)
            for (frame, text) in dumps.sorted(by: { $0.key < $1.key }) {
                XCTAssertGreaterThan(text.split(separator: "\n").count, 40, "\(scene.name)@\(frame): the tree is nearly empty")
                if let out { try text.write(to: out.appendingPathComponent("\(scene.name)@\(frame).tree.txt"), atomically: true, encoding: .utf8) }
            }
        }
    }

    /// The same scene built twice gives the same tree (the driver is frame-pure, as the harness's A/A).
    func testPreviewTreesAreDeterministic() async {
        guard let scene = PlazaPreviewScenes.all.first(where: { $0.name == "pond-swim" }) else { return XCTFail("no pond-swim") }
        var first: [String] = [], second: [String] = []
        await PlazaPreviewScenes.run(scene, stage: PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) { _, s in first.append(PlazaPreviewScenes.dump(s)) }
        await PlazaPreviewScenes.run(scene, stage: PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) { _, s in second.append(PlazaPreviewScenes.dump(s)) }
        XCTAssertEqual(first.count, scene.captures.count)
        XCTAssertEqual(first, second)
    }
}
