import CoreGraphics
import XCTest
@testable import PokeTokenBar

/// Legacy oracle (D5) for the photo: the canvas-composed photo has the very RGBA bytes and PNG bytes the CoreGraphics
/// renderer gave (`Legacy/LegacyPlazaPhotoRenderer.swift`). Mac only.
@MainActor
final class PlazaPhotoParityTests: XCTestCase {
    // MARK: the oracle

    private func legacy(_ i: PlazaPhotoInput) -> LegacyPlazaPhotoInput {
        func particle(_ p: PlazaPhotoParticle) -> LegacyPlazaPhotoParticle {
            LegacyPlazaPhotoParticle(image: p.image.cgImage, origin: p.origin, size: p.size, alpha: p.alpha)
        }
        let actors = i.actors.map { a -> LegacyPlazaPhotoActor in
            LegacyPlazaPhotoActor(image: a.image.cgImage, flipped: a.flipped, foot: a.foot, bob: a.bob, scale: a.scale,
                                          shadow: a.shadow?.cgImage, shadowRect: a.shadowRect, front: a.front?.cgImage,
                                          plate: a.plate?.cgImage, bubble: a.bubble?.cgImage, opacity: a.opacity,
                                          plateBaseY: a.plateBaseY, sink: a.sink, waterClip: a.waterClip, eggSunk: a.eggSunk,
                                          lift: a.lift, squash: a.squash, tilt: a.tilt)
        }
        return LegacyPlazaPhotoInput(
            mapImage: i.mapImage.cgImage, visibleRect: i.visibleRect, pixelsPerWorld: i.pixelsPerWorld, actors: actors, tint: i.tint,
            weather: i.weather.map(particle), items: i.items.map(particle), ice: i.ice.map(particle),
            bands: i.bands.map { LegacyPlazaPhotoBand(image: $0.image.cgImage, origin: $0.origin, size: $0.size, sortY: $0.sortY) },
            props: i.props.map { LegacyPlazaPhotoProp(particle: particle($0.particle), baseY: $0.baseY) },
            light: i.light, fireworks: i.fireworks.map(particle), fireworkLight: i.fireworkLight)
    }

    /// Raw RGBA bytes (format and every data-provider byte) and PNG bytes, old against new. Returns the new image.
    @discardableResult
    private func assertPhotoIdentical(_ input: PlazaPhotoInput, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> PlazaImage? {
        let old = LegacyPlazaPhotoRenderer.render(legacy(input))
        let new = PlazaPhotoRenderer.render(input)
        guard let old, let new else {
            XCTAssertNil(old, "\(label): only the legacy renderer made a photo", file: file, line: line)
            XCTAssertNil(new, "\(label): only the new renderer made a photo", file: file, line: line)
            return nil
        }
        PlazaArtParity.assertIdentical(old, new, label, file: file, line: line)
        XCTAssertEqual(LegacyPlazaPhotoRenderer.png(old), PlazaPhotoRenderer.pngData(for: input), "\(label): PNG bytes", file: file, line: line)
        return new
    }

    // MARK: the harness scenes

    /// Every harness scene that takes a photo, plus scenes that put other inputs in front of it (seasons, ice, items,
    /// Ditto, plates, bubbles, emotes, snowballs, pond egg, high zoom).
    private static let extraScenes: Set<String> = [
        "zoom-1", "zoom-4", "dusk", "spring", "autumn", "campfire-ready", "campfire-smoke", "pond-egg", "ice-frozen", "ice-breaking",
        "pray-wobble", "emotes", "chat-bubbles", "name-plates", "ditto", "ditto-decoy", "ditto-poof", "fireworks-day", "snowballs",
        "items", "photo-mode", "winter-footprints",
    ]

    func testPhotoIsByteIdenticalForTheHarnessScenes() throws {
        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        var seen: [String: PlazaPhotoInput] = [:]
        PlazaRenderRun.photoInputObserver = { name, input in seen[name] = input }
        defer { PlazaRenderRun.photoInputObserver = nil }
        let scenes = PlazaRenderScenes.all.filter { s in
            Self.extraScenes.contains(s.name) || ["base-noon", "night", "winter-snow", "pond-swim", "tall-grass", "campfire-lit-night",
                                                  "fireworks-night", "dance"].contains(s.name)
        }
        for scene in scenes { _ = PlazaRenderRun.run(scene, renderer: renderer) }
        XCTAssertEqual(Set(seen.keys), Set(scenes.map(\.name)))
        for name in seen.keys.sorted() { assertPhotoIdentical(seen[name]!, "scene \(name)") }
        // What the scenes cover: swimmers, tall-grass bands, fire props and light, firework light, ice, weather, plates, bubbles.
        let inputs = Array(seen.values)
        XCTAssertTrue(inputs.contains { $0.actors.contains { $0.sink > 0 && $0.waterClip != nil } }, "a swimmer")
        XCTAssertTrue(inputs.contains { $0.actors.contains { $0.eggSunk } }, "an egg in the water")
        XCTAssertTrue(inputs.contains { !$0.bands.isEmpty }, "tall-grass bands")
        XCTAssertTrue(inputs.contains { !$0.props.isEmpty && $0.light != nil }, "a lit campfire")
        XCTAssertTrue(inputs.contains { $0.fireworkLight != nil && !$0.fireworks.isEmpty }, "fireworks and their light")
        XCTAssertTrue(inputs.contains { !$0.ice.isEmpty }, "ice")
        XCTAssertTrue(inputs.contains { !$0.weather.isEmpty }, "weather")
        XCTAssertTrue(inputs.contains { !$0.items.isEmpty }, "an item")
        XCTAssertTrue(inputs.contains { $0.actors.contains { $0.flipped } }, "a mirrored actor")
        XCTAssertTrue(inputs.contains { $0.actors.contains { $0.plate != nil } && $0.actors.contains { $0.bubble != nil } }, "plates and bubbles")
        XCTAssertTrue(inputs.contains { $0.tint != .none }, "a tint")
        XCTAssertTrue(inputs.contains { $0.actors.contains { $0.opacity < 1 } }, "an actor hidden in tall grass")
    }

    // MARK: synthetic inputs

    /// A patterned image (no two neighbouring pixels alike) so a mirrored, rotated or shifted draw cannot match by accident.
    private func pattern(_ w: Int, _ h: Int, seed: Int, alpha: Bool = true) -> PlazaImage {
        var bitmap = PlazaBitmap(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let a = alpha ? UInt8((x * 37 + y * 11 + seed) % 5 == 0 ? 0 : 160 + (x + y + seed) % 96) : 255
                func c(_ v: Int) -> UInt8 { UInt8(min(Int(a), (v * 29 + seed * 7) % 256)) }
                bitmap[x, y] = PlazaRGBA(r: c(x * 5 + y), g: c(y * 9 + x * 2), b: c(x * y + seed), a: a)
            }
        }
        return PlazaImage(bitmap: bitmap)
    }

    private func actor(_ x: CGFloat, _ y: CGFloat, seed: Int, flipped: Bool = false, plate: Bool = true, bubble: Bool = true) -> PlazaPhotoActor {
        PlazaPhotoActor(image: pattern(20, 28, seed: seed), flipped: flipped, foot: CGPoint(x: x, y: y), bob: 1.5, scale: 1.5,
                        shadow: pattern(24, 8, seed: seed + 1), shadowRect: CGRect(x: x - 12, y: y - 5, width: 24, height: 8),
                        front: pattern(24, 8, seed: seed + 2), plate: plate ? pattern(18, 6, seed: seed + 3) : nil,
                        bubble: bubble ? pattern(22, 10, seed: seed + 4) : nil)
    }

    private func scene(ppw: Int = 4, rect: CGRect = CGRect(x: 7.3, y: 4.6, width: 120, height: 90),
                       _ variant: (inout PlazaPhotoInput) -> Void = { _ in }) -> PlazaPhotoInput {
        var input = PlazaPhotoInput(mapImage: pattern(160, 120, seed: 1, alpha: false), visibleRect: rect,
                                    pixelsPerWorld: ppw, actors: [actor(40, 50, seed: 10), actor(70, 40, seed: 20, flipped: true),
                                                                actor(90, 70, seed: 30, plate: false, bubble: false)])
        variant(&input)
        return input
    }

    func testPhotoIsByteIdenticalForSyntheticInputs() {
        let pond = CGRect(x: 30, y: 40, width: 40, height: 30)
        let light = PlazaPhotoLight(center: CGPoint(x: 60, y: 50), radii: CGSize(width: 24, height: 18), tint: PlazaDaylight.Tint(red: 0.3, green: 0.4, blue: 0.7))
        let variants: [(String, (inout PlazaPhotoInput) -> Void)] = [
            ("plain", { _ in }),
            ("mirrored only", { $0.actors = [self.actor(60, 60, seed: 5, flipped: true)] }),
            ("tilted and squashed", { $0.actors[0].tilt = 0.4; $0.actors[0].squash = 1.3; $0.actors[1].tilt = -0.2; $0.actors[1].lift = 3 }),
            ("tilted mirrored", { $0.actors[1].tilt = 0.7; $0.actors[1].squash = 0.8 }),
            ("swimming", { $0.actors[0].sink = 9; $0.actors[0].waterClip = pond; $0.actors[1].sink = 5.5; $0.actors[1].waterClip = pond }),
            ("swimming without a pond", { $0.actors[0].sink = 9 }),
            ("egg sunk", { $0.actors[0].eggSunk = true; $0.actors[0].waterClip = pond }),
            ("egg sunk at the pond's top row", { $0.actors[0].eggSunk = true; $0.actors[0].waterClip = CGRect(x: 30, y: 52, width: 40, height: 20) }),
            ("egg sunk, hidden in grass", { $0.actors[1].eggSunk = true; $0.actors[1].waterClip = pond; $0.actors[1].opacity = 0.5 }),
            ("tall grass", { $0.actors[0].opacity = 0.4; $0.actors[0].plateBaseY = 45; $0.actors[2].opacity = 0 }),
            ("bands", { $0.bands = [PlazaPhotoBand(image: self.pattern(32, 32, seed: 50), origin: CGPoint(x: 32, y: 32), size: CGSize(width: 32, height: 32), sortY: 63),
                                    PlazaPhotoBand(image: self.pattern(32, 32, seed: 51), origin: CGPoint(x: 64, y: 40), size: CGSize(width: 32, height: 32), sortY: 71)] }),
            ("props", { $0.props = [PlazaPhotoProp(particle: PlazaPhotoParticle(image: self.pattern(12, 14, seed: 60), origin: CGPoint(x: 50, y: 45), size: CGSize(width: 12, height: 14)), baseY: 55)] }),
            ("ice and items", { $0.ice = [PlazaPhotoParticle(image: self.pattern(40, 30, seed: 70), origin: CGPoint(x: 30, y: 40), size: CGSize(width: 40, height: 30), alpha: 0.6)]
                $0.items = [PlazaPhotoParticle(image: self.pattern(8, 8, seed: 71), origin: CGPoint(x: 75, y: 55), size: CGSize(width: 8, height: 8))] }),
            ("weather", { $0.weather = (0..<12).map { PlazaPhotoParticle(image: self.pattern(3, 3, seed: 80 + $0), origin: CGPoint(x: Double($0) * 9.7, y: Double($0) * 6.1), size: CGSize(width: 3, height: 3), alpha: 0.8) } }),
            ("night tint", { $0.tint = PlazaDaylight.Tint(red: 0.4, green: 0.5, blue: 0.8) }),
            ("campfire light", { $0.tint = PlazaDaylight.Tint(red: 0.4, green: 0.5, blue: 0.8); $0.light = light }),
            ("firework light and sparks", { $0.tint = PlazaDaylight.Tint(red: 0.4, green: 0.5, blue: 0.8)
                $0.fireworkLight = PlazaPhotoLight(center: CGPoint(x: 80, y: 30), radii: CGSize(width: 30, height: 30), tint: $0.tint, color: (0.9, 0.5, 0.2), level: 0.6)
                $0.fireworks = [PlazaPhotoParticle(image: self.pattern(6, 6, seed: 90), origin: CGPoint(x: 78, y: 28), size: CGSize(width: 6, height: 6))] }),
            ("both lights", { $0.tint = PlazaDaylight.Tint(red: 0.4, green: 0.5, blue: 0.8); $0.light = light
                $0.fireworkLight = PlazaPhotoLight(center: CGPoint(x: 5, y: 5), radii: CGSize(width: 20, height: 14), tint: $0.tint) }),
            ("light off the picture's edge", { $0.light = PlazaPhotoLight(center: CGPoint(x: 0, y: 0), radii: CGSize(width: 24, height: 20), tint: PlazaDaylight.Tint(red: 0.2, green: 0.3, blue: 0.6)) }),
            ("plates pushed in at the edges", { $0.actors = [self.actor(8, 6, seed: 3), self.actor(125, 90, seed: 4), self.actor(-30, 30, seed: 6)] }),
            ("no actors", { $0.actors = [] }),
        ]
        for (name, make) in variants {
            XCTAssertNotNil(assertPhotoIdentical(scene(make), name), name)
        }
        XCTAssertNotNil(assertPhotoIdentical(scene(ppw: 3, rect: CGRect(x: 0.5, y: 0, width: 20.5, height: 10)), "odd ratio"))
        // The same renderers refuse the same inputs.
        XCTAssertNil(assertPhotoIdentical(scene(rect: .zero), "empty rect"))
        XCTAssertNil(assertPhotoIdentical(scene(ppw: 0), "zero scale"))
        XCTAssertNil(assertPhotoIdentical(scene(rect: CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)), "too big"))
    }

    // MARK: PNG and the clipboard

    func testPNGComesFromTheGraphicsEncoder() throws {
        let input = scene()
        let image = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        XCTAssertEqual(PlazaPhotoRenderer.pngData(for: input), PlatformPlaza.graphics.encodePNG(image))
        XCTAssertNil(PlazaPhotoRenderer.pngData(for: scene(ppw: 0)))
    }

    func testTheMacClipboardIsThePasteboardBackend() {
        XCTAssertTrue(PlatformPlaza.clipboard is MacImageClipboard)
    }
}
