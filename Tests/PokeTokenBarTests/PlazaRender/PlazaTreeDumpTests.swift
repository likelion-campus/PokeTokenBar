import XCTest
@testable import PokeTokenBar

/// The shared tree's dump is the very fact the SpriteKit dump states (Task 15 compares shared dumps across OSes, so this
/// is what makes that compare a statement about the SpriteKit scene). Offscreen, like every harness test.
@MainActor
final class PlazaRenderTreeDumpTests: XCTestCase {
    /// Every capture of every harness scene: the dump made from the shared tree equals the dump made from the
    /// SpriteKit tree, line for line.
    func testSharedDumpEqualsTheSpriteKitDumpOnEveryHarnessCapture() throws {
        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        var captures = 0, lines = 0
        PlazaRenderScenes.installMacHooks()
        for scene in PlazaRenderScenes.all {
            for c in PlazaRenderRun.run(scene, renderer: renderer).captures {
                captures += 1
                lines += c.nodes
                // The SpriteKit dump's texture hash names the sheet a cut shares (see PlazaTreeDump); the region lines hash the cut itself.
                XCTAssertEqual(Self.withoutHashes(c.skRegionTree), Self.withoutHashes(c.tree), "\(c.scene)@\(c.frame): the region dump is the dump but for the hashes")
                if c.sharedTree != c.skRegionTree {
                    let shared = c.sharedTree.split(separator: "\n", omittingEmptySubsequences: false)
                    let sk = c.skRegionTree.split(separator: "\n", omittingEmptySubsequences: false)
                    let at = zip(shared, sk).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(shared.count, sk.count)
                    XCTFail("\(c.scene)@\(c.frame): dumps differ at line \(at + 1) of \(sk.count)\n  shared: \(at < shared.count ? String(shared[at]) : "(end)")\n  sk:     \(at < sk.count ? String(sk[at]) : "(end)")")
                }
            }
        }
        XCTAssertGreaterThan(captures, 20, "the harness scenes ran")
        print("PLAZA-TREEDUMP: \(captures) captures, \(lines) node lines equal")
    }

    private static func withoutHashes(_ dump: String) -> String {
        dump.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let hash = line.range(of: "#", options: .backwards), line[hash.upperBound...].allSatisfy(\.isHexDigit) else { return String(line) }
            return String(line[..<hash.lowerBound])
        }.joined(separator: "\n")
    }

    /// The format itself, on a hand-built tree (what a Windows test can also check): fixed formats, ordinals by first
    /// appearance, a cut texture hashes its own pixels, the camera and a crop mask print as the SpriteKit dump does.
    func testFormatOnAHandBuiltTree() {
        let root = PlazaNode(), camera = PlazaCameraNode()
        root.name = "world"
        root.addChild(camera)
        let image = PlazaImage(bitmap: PlazaTestImages.patterned(width: 4, height: 2))
        let whole = PlazaTexture(image)
        let sprite = PlazaSprite(texture: whole, size: CGSize(width: 4, height: 2))
        sprite.position = CGPoint(x: 1.5, y: -2)
        sprite.color = PlazaColor(srgbRed: 0.25, green: 0.5, blue: 1, alpha: 1)
        sprite.colorBlendFactor = 0.3
        sprite.blendMode = .multiplyX2
        let crop = PlazaCropNode()
        crop.maskRect = CGRect(x: 1, y: 2, width: 3, height: 4)
        crop.addChild(PlazaSprite(texture: PlazaTexture(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), in: whole), size: CGSize(width: 2, height: 2)))
        root.addChild(sprite)
        root.addChild(crop)
        camera.addChild(PlazaSprite(color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5), size: CGSize(width: 8, height: 8)))
        let lines = PlazaTreeDump.lines(root: root, camera: camera, classNames: [ObjectIdentifier(root): "PlazaScene"])
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[0], "PlazaScene name=world p=0,0 z=0 a=1.0000 h=0 sc=1.0000,1.0000 rot=0")
        XCTAssertEqual(lines[1], " SKCameraNode name=- p=0,0 z=0 a=1.0000 h=0 sc=1.0000,1.0000 rot=0")
        XCTAssertTrue(lines[2].hasPrefix("  SKSpriteNode ") && lines[2].contains("color=0,0,0,0.5000") && !lines[2].contains("tex"), lines[2])
        XCTAssertTrue(lines[3].hasPrefix(" SKSpriteNode name=- p=1.5000,-2.0000 z=0 a=1.0000 h=0 sc=1.0000,1.0000 rot=0 size=4.0000x2.0000 anchor=0.5000,0.5000 color=0.2500,0.5000,1.0000,1.0000 cbf=0.3000 blend=4 tex0:4x2#"), lines[3])
        XCTAssertTrue(lines[4].hasPrefix(" SKCropNode name=- p=0,0 z=0 a=1.0000 h=0 sc=1.0000,1.0000 rot=0 mask=SKSpriteNode p=1.0000,2.0000 frame=1.0000,2.0000,3.0000,4.0000"), lines[4])
        XCTAssertTrue(lines[5].contains(" tex1:2x2#"), lines[5])
        XCTAssertNotEqual(lines[3].components(separatedBy: "#").last, lines[5].components(separatedBy: "#").last, "a cut hashes its own pixels")
    }
}
