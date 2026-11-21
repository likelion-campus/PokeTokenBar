import Foundation
import XCTest
@testable import PokeTokenBar

/// Writes and re-checks the Mac's photo goldens (`PlazaPhotoGoldens`). Mac only: the goldens are by definition what this Mac makes.
@MainActor
final class PlazaPhotoGoldensMacTests: XCTestCase {
    /// The goldens are made in UTC. Instead of skipping on any other zone (which let a stale golden pass every local run and fail only on
    /// Windows CI, whose runner is UTC), this test run puts the process in UTC and puts the zone back afterwards.
    private func requireUTC() throws {
        let before = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        addTeardownBlock { NSTimeZone.default = before }
    }

    func testWritePhotoGoldens() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PTB_PLAZA_GOLDENS_WRITE"] == "1", "PTB_PLAZA_GOLDENS_WRITE=1 writes the photo goldens")
        try requireUTC()
        try FileManager.default.createDirectory(at: PlazaPhotoGoldens.directory, withIntermediateDirectories: true)
        var manifest = PlazaPhotoGoldenManifest(scenes: [:])
        for scene in PlazaPreviewScenes.photoScenes {
            let made = await PlazaPhotoGoldens.photoInput(scene)
            let input = try XCTUnwrap(made, scene.name)
            let image = try XCTUnwrap(PlazaPhotoRenderer.render(input), scene.name)
            let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(image), scene.name)
            try png.write(to: PlazaPhotoGoldens.pngURL(scene.name))
            let cells = PlazaPhotoGoldens.plateCells(input, photo: image)
            XCTAssertFalse(cells.isEmpty, "\(scene.name): no plate or bubble in the photo")
            manifest.scenes[scene.name] = .init(width: image.width, height: image.height, plateCells: cells.sorted { ($0[1], $0[0]) < ($1[1], $1[0]) })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(manifest) + Data("\n".utf8)).write(to: PlazaPhotoGoldens.directory.appendingPathComponent("manifest.json"))
    }

    /// Every Mac run: the photos this Mac makes are the committed goldens, byte for byte.
    func testPhotoGoldensStillHoldOnThisMac() async throws {
        try requireUTC()
        let manifest = try PlazaPhotoGoldens.loadManifest()
        XCTAssertEqual(manifest.scenes.keys.sorted(), PlazaPreviewScenes.photoScenes.map(\.name).sorted())
        for scene in PlazaPreviewScenes.photoScenes {
            let made = await PlazaPhotoGoldens.photoInput(scene)
            let input = try XCTUnwrap(made, scene.name)
            let image = try XCTUnwrap(PlazaPhotoRenderer.render(input), scene.name)
            let golden = try XCTUnwrap(PlatformPlaza.graphics.decodeImage(Data(contentsOf: PlazaPhotoGoldens.pngURL(scene.name))), scene.name)
            XCTAssertEqual(image.width, golden.width, scene.name)
            XCTAssertEqual(image.height, golden.height, scene.name)
            XCTAssertTrue(image.pixels.bytes == golden.pixels.bytes, "\(scene.name): the photo is not the committed golden")
        }
    }
}
