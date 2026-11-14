import AppKit
import CryptoKit
import Metal
import SpriteKit
import XCTest
@testable import PokeTokenBar

/// Offscreen render harness for the plaza scene (windows-port Track A, Task 1). Mac only: SpriteKit + Metal.
/// Everything here is offscreen: no window, no SKView, no activation. See `scripts/plaza-render-compare.sh`.
///
/// Env (every harness test XCTSkips without its variable):
///  PTB_PLAZA_RENDER_OUT=<dir>      render every scene into <dir>
///  PTB_PLAZA_RENDER_A / _B=<dir>   compare two output directories
///  PTB_PLAZA_RENDER_ONLY=a,b       restrict to these scene names
///  PTB_PLAZA_RENDER_SPRITES=<dir>  real cached GIFs (read only) for `real-sprites`
///  PTB_PLAZA_FRAMECOST_OUT=<file>, PTB_PLAZA_FRAMECOST_FRAMES=<n>
enum PlazaRenderEnv {
    static func value(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty ?? true) ? nil : v
    }
    static var only: Set<String>? {
        value("PTB_PLAZA_RENDER_ONLY").map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    }
}

/// The plan's single adapter: the harness reaches the SpriteKit scene only through here.
enum PlazaRenderHarness {
    /// The `SKScene` the Mac's stage draws the shared scene into (what the window's `SKView` presents).
    @MainActor static func skScene(of scene: PlazaScene) -> SKScene { (scene.stage as! SpriteKitStage).skScene }

    /// The shared tree, compared with its SpriteKit copy after every capture (`PlazaMirrorParity`). Since Task 10 the
    /// whole scene is one shared tree under the stage root, whose copy is the `SKScene` itself.
    @MainActor static func sharedRoots(of scene: PlazaScene) -> [PlazaNode] { [scene.root] }

    /// Every actor of the scene: mine, the teammates' and the Ditto's.
    @MainActor static func actors(of scene: PlazaScene) -> [PlazaActor] {
        [scene.myActor] + (scene.memberTiles.keys.sorted() + [PlazaDitto.sceneKey]).compactMap(scene.memberActor)
    }

    /// An actor's node whose SpriteKit copy is not where `attach` put it (world nodes straight in the `SKScene`, the
    /// rest in its camera). Kept beside the root parity: it names the actor when a detach or an attach goes wrong.
    @MainActor static func actorMountDifferences(of scene: PlazaScene) -> [String] {
        let sk = skScene(of: scene)
        return actors(of: scene).flatMap { actor in
            actor.worldNodes.filter { $0.skNode?.parent !== sk }.map { "actor \(actor.name): \(type(of: $0)) is not in the scene" }
                + actor.cameraNodes.filter { sk.camera == nil || $0.skNode?.parent !== sk.camera }.map { "actor \(actor.name): \(type(of: $0)) is not in the camera" }
        }
    }

    /// The class a node had before Track A (an `SKNode` subclass; now the copy of a shared node), so tree dumps still
    /// compare with bases from before the conversion. Only the printed class name is mapped.
    @MainActor static func legacyClassNames(of scene: PlazaScene) -> [ObjectIdentifier: String] {
        var out: [ObjectIdentifier: String] = [ObjectIdentifier(skScene(of: scene)): "PlazaScene"]
        for (root, name) in layerRoots(of: scene) { if let sk = root.skNode { out[ObjectIdentifier(sk)] = name } }
        return out
    }

    /// Every converted layer's root with the class name its node had before.
    @MainActor private static func layerRoots(of scene: PlazaScene) -> [(root: PlazaNode, name: String)] {
        var out: [(root: PlazaNode, name: String)] = []
        if let l = scene.tallGrassLayer { out.append((l.root, "PlazaTallGrassLayer")) }
        if let l = scene.pondLayer { out.append((l.root, "PlazaPondLayer")) }
        if let l = scene.iceLayer { out.append((l.root, "PlazaIceLayer")) }
        out.append((scene.weatherLayer.root, "PlazaWeatherLayer"))
        out.append((scene.fireworkLayer.root, "PlazaFireworkLayer"))
        out.append((scene.footprintLayer.root, "PlazaFootprintLayer"))
        out.append((scene.snowballLayer.root, "PlazaSnowballLayer"))
        return out
    }
}

/// One `SKRenderer` into a `.bgra8Unorm` texture. Quirks found on the way (hard-won, see the plan's R6):
/// `renderer.update(atTime:)` resets `scene.size`, so size is set before and after; the first passes can be black;
/// `SKScene.backgroundColor` is not drawn by `SKRenderer` (the scene's own sprites are).
@MainActor
final class PlazaOffscreenRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var renderer: SKRenderer
    private var target: MTLTexture?
    /// Never 0: `SKRenderer.update(atTime: 0)` substitutes the wall clock for the first call (probe), which is not deterministic.
    static let clockBase: TimeInterval = 1000

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true   // the app's SKView sets it (PlazaWindowController)
    }

    /// A new `SKRenderer` for the next scene: one renderer keeps a monotonic time base, so reusing it after a run that
    /// ended at t=1.5 s and starting the next scene at t=0 again gives that scene different frame deltas (probe/A-A finding).
    func startFresh() {
        renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true
    }

    /// One update + draw. `points` is the scene size, `pixels` the target size (points x backing).
    func pass(_ scene: SKScene, points: CGSize, pixels: (width: Int, height: Int), time: TimeInterval, beforeRender: (() -> Void)? = nil, afterRender: (() -> Void)? = nil) {
        if target?.width != pixels.width || target?.height != pixels.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels.width, height: pixels.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            target = device.makeTexture(descriptor: d)
        }
        guard let target else { return }
        scene.scaleMode = .fill   // .resizeFill (PlazaScene's) makes `update(atTime:)` reset size to 0x0 BEFORE it calls scene.update (probe)
        scene.size = points
        if renderer.scene !== scene { renderer.scene = scene }   // re-assigning every pass restarts the scene clock (probe)
        renderer.update(atTime: Self.clockBase + time)   // calls scene.update(_:) and runs actions; time 0 would mean wall clock (probe)
        scene.size = points   // `update(atTime:)` reset it
        beforeRender?()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer() else { return }
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height), commandBuffer: buffer, renderPassDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()
        afterRender?()
    }

    func bytes() -> [UInt8] {
        guard let target else { return [] }
        var out = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&out, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return out
    }
}

struct PlazaRenderCapture {
    let scene: String
    let frame: Int
    let width: Int
    let height: Int
    let bgra: [UInt8]
    let tree: String
    let nodes: Int
    let textures: Int
    let ties: [String]
    /// Where a shared subtree and its SpriteKit copy disagree (must be empty).
    var parity: [String] = []
}

@MainActor
enum PlazaRenderRun {
    static func hex(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func hex(_ string: String) -> String { hex(Array(string.utf8)) }

    /// Warm-up passes at t = 0 before frame 1 (the first passes can be black), and extra same-time passes at every
    /// capture (dt = 0, so nothing advances) so textures created that very frame have been drawn once.
    static let warmUpPasses = 15
    /// z nudge per tie rank; well above Float32 resolution at the plaza's z range (<12), well below the plaza's finest z step (2e-4).
    static let tieStep: CGFloat = 5e-6

    struct Photo { let png: Data; let rgbaSHA256: String }

    /// Set by the photo parity test: sees the photo input of every scene at the end of its run (scene name, input).
    static var photoInputObserver: ((String, PlazaPhotoInput) -> Void)?

    static func run(_ scene: PlazaRenderScene, renderer: PlazaOffscreenRenderer) -> (captures: [PlazaRenderCapture], photo: Photo?) {
        renderer.startFresh()
        let setup = scene.build()
        let sk = PlazaRenderHarness.skScene(of: setup.scene)
        let pixels = (width: Int(scene.viewport.width * scene.backing), height: Int(scene.viewport.height * scene.backing))
        var out: [PlazaRenderCapture] = []
        setup.step(0)
        for _ in 0..<warmUpPasses { renderer.pass(sk, points: scene.viewport, pixels: pixels, time: 0) }
        let last = scene.captures.max() ?? 0
        guard last > 0 else { return (out, nil) }
        for frame in 1...last {
            setup.step(frame)
            let t = Double(frame) / 60
            renderer.pass(sk, points: scene.viewport, pixels: pixels, time: t)
            if scene.captures.contains(frame) {
                var dump = PlazaTreeDump()
                dump.classNames = PlazaRenderHarness.legacyClassNames(of: setup.scene)
                dump.walk(sk)
                // Exact z ties between overlapping sprites are drawn in an unspecified order by SKRenderer with ignoresSiblingOrder
                // (found by the A/A: weather particles flip between runs). The harness resolves them in tree order for the
                // capture only (a z nudge applied after the update and undone after the draw); `ties.txt` lists them.
                let tied = dump.tiedSprites()
                var saved: [(SKNode, CGFloat)] = []
                let nudge: () -> Void = {
                    saved = tied.map { ($0.node, $0.node.zPosition) }
                    for t in tied { t.node.zPosition += t.rank * PlazaRenderRun.tieStep }
                }
                let restore: () -> Void = { for (n, z) in saved { n.zPosition = z } }
                for pass in 0..<warmUpPasses {
                    renderer.pass(sk, points: scene.viewport, pixels: pixels, time: t, beforeRender: pass == warmUpPasses - 1 ? nudge : nil,
                                  afterRender: pass == warmUpPasses - 1 ? restore : nil)
                }
                var capture = PlazaRenderCapture(scene: scene.name, frame: frame, width: pixels.width, height: pixels.height,
                                                 bgra: renderer.bytes(), tree: dump.lines.joined(separator: "\n") + "\n",
                                                 nodes: dump.lines.count, textures: dump.textureCount, ties: dump.ties())
                capture.parity = PlazaRenderHarness.sharedRoots(of: setup.scene).flatMap { PlazaMirrorParity.differences($0) }
                    + PlazaRenderHarness.actorMountDifferences(of: setup.scene)
                out.append(capture)
            }
        }
        if let observe = photoInputObserver, let input = setup.scene.photoInput() { observe(scene.name, input) }
        var photo: Photo?
        if setup.photo, let input = setup.scene.photoInput(), let image = PlazaPhotoRenderer.render(input),
           let png = PlatformPlaza.graphics.encodePNG(image), let data = image.cgImage.dataProvider?.data as Data? {
            photo = Photo(png: png, rgbaSHA256: hex(Array(data)))
        }
        return (out, photo)
    }

    static func write(_ captures: [PlazaRenderCapture], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for c in captures {
            let stem = "\(c.scene)@\(c.frame)"
            try Data(c.bgra).write(to: dir.appendingPathComponent("\(stem).bgra"))
            try c.tree.write(to: dir.appendingPathComponent("\(stem).tree.txt"), atomically: true, encoding: .utf8)
            if let png = png(bgra: c.bgra, width: c.width, height: c.height) {
                try png.write(to: dir.appendingPathComponent("\(stem).png"))
            }
        }
    }

    static func png(bgra: [UInt8], width: Int, height: Int) -> Data? {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// manifest.tsv: scene frame sha256(bgra) sha256(tree) nodes textures. Sorted by scene then frame.
    static func manifest(_ captures: [PlazaRenderCapture]) -> String {
        captures.sorted { ($0.scene, $0.frame) < ($1.scene, $1.frame) }
            .map { "\($0.scene)\t\($0.frame)\t\(hex($0.bgra))\t\(hex($0.tree))\t\($0.nodes)\t\($0.textures)" }
            .joined(separator: "\n") + "\n"
    }

    /// Equal-z overlapping sprites with different textures (the tie audit), unique lines over all captures.
    static func tieReport(_ captures: [PlazaRenderCapture]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for c in captures.sorted(by: { ($0.scene, $0.frame) < ($1.scene, $1.frame) }) {
            for t in c.ties where seen.insert("\(c.scene)|\(t)").inserted { lines.append("\(c.scene)@\(c.frame)\t\(t)") }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

/// One line per SpriteKit node. Deterministic text: fixed number formats, texture ordinals by first appearance.
@MainActor
struct PlazaTreeDump {
    private(set) var lines: [String] = []
    private var ordinals: [ObjectIdentifier: Int] = [:]
    private var textureHashes: [ObjectIdentifier: String] = [:]
    private var sprites: [(node: SKSpriteNode, path: String, rect: CGRect, z: CGFloat, texture: Int)] = []
    var textureCount: Int { ordinals.count }
    /// Printed class names for given nodes (`PlazaRenderHarness.legacyClassNames`).
    var classNames: [ObjectIdentifier: String] = [:]
    private func className(_ node: SKNode) -> String { classNames[ObjectIdentifier(node)] ?? "\(type(of: node))" }

    private func f(_ v: CGFloat) -> String {
        let r = (Double(v) * 10000).rounded() / 10000
        return r == 0 ? "0" : String(format: "%.4f", r)
    }
    private func p(_ v: CGPoint) -> String { "\(f(v.x)),\(f(v.y))" }
    private func s(_ v: CGSize) -> String { "\(f(v.width))x\(f(v.height))" }

    private func components(_ color: SKColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "?" }
        return "\(f(c.redComponent)),\(f(c.greenComponent)),\(f(c.blueComponent)),\(f(c.alphaComponent))"
    }

    private mutating func texture(_ t: SKTexture) -> String {
        let id = ObjectIdentifier(t)
        let ordinal: Int
        if let o = ordinals[id] { ordinal = o } else { ordinal = ordinals.count; ordinals[id] = ordinal }
        if textureHashes[id] == nil {
            let image = t.cgImage()
            let data = image.dataProvider?.data as Data?
            textureHashes[id] = "\(image.width)x\(image.height)#" + String(PlazaRenderRun.hex(Array(data ?? Data())).prefix(16))
        }
        return "tex\(ordinal):\(textureHashes[id]!)"
    }

    mutating func walk(_ node: SKNode, depth: Int = 0, parentZ: CGFloat = 0, path: String = "") {
        let globalZ = parentZ + node.zPosition
        var line = String(repeating: " ", count: depth)
            + "\(className(node)) name=\(node.name ?? "-") p=\(p(node.position)) z=\(f(node.zPosition)) a=\(f(node.alpha))"
            + " h=\(node.isHidden ? 1 : 0) sc=\(f(node.xScale)),\(f(node.yScale)) rot=\(f(node.zRotation))"
        if let sprite = node as? SKSpriteNode {
            line += " size=\(s(sprite.size)) anchor=\(p(sprite.anchorPoint)) color=\(components(sprite.color))"
                + " cbf=\(f(sprite.colorBlendFactor)) blend=\(sprite.blendMode.rawValue)"
            if let t = sprite.texture {
                let desc = texture(t)
                line += " \(desc)"
                if !node.isHidden && node.alpha > 0 && !isUnderHidden(node) {
                    sprites.append((node: sprite, path: path + "/" + (node.name ?? className(node)), rect: sprite.frame.applying(accumulated(node)), z: globalZ,
                                    texture: ordinals[ObjectIdentifier(t)] ?? -1))
                }
            }
        }
        if let crop = node as? SKCropNode {
            line += " mask=\(crop.maskNode.map { "\(type(of: $0)) p=\(p($0.position)) frame=\(f($0.frame.minX)),\(f($0.frame.minY)),\(f($0.frame.width)),\(f($0.frame.height))" } ?? "nil")"
        }
        lines.append(line)
        for child in node.children { walk(child, depth: depth + 1, parentZ: globalZ, path: path + "/" + (node.name ?? className(node))) }
    }

    private func isUnderHidden(_ node: SKNode) -> Bool {
        var n = node.parent
        while let x = n { if x.isHidden || x.alpha == 0 { return true }; n = x.parent }
        return false
    }

    /// Node's frame is in its parent's space; `accumulated` maps it to scene space ignoring rotation.
    private func accumulated(_ node: SKNode) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var n = node.parent
        while let x = n, !(x is SKScene) {
            t = t.concatenating(CGAffineTransform(scaleX: x.xScale, y: x.yScale).concatenating(CGAffineTransform(translationX: x.position.x, y: x.position.y)))
            n = x.parent
        }
        return t
    }

    /// Pairs of visible sprites with the same global z whose rects overlap (any textures).
    private func tiePairs() -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for i in 0..<sprites.count {
            for j in (i + 1)..<max(i + 1, sprites.count) where sprites[i].z == sprites[j].z && sprites[i].rect.intersects(sprites[j].rect) { pairs.append((i, j)) }
        }
        return pairs
    }

    func ties() -> [String] {
        var out = Set<String>()
        for (i, j) in tiePairs() {
            let a = sprites[i], b = sprites[j]
            out.insert("z=\(f(a.z))\t\(a.path)#tex\(a.texture)\t\(b.path)#tex\(b.texture)\(a.texture == b.texture ? "\tsame-texture" : "")")
        }
        return out.sorted()
    }

    /// Sprites taking part in a tie with the rank (0, 1, 2...) of each among the tied sprites of its z, in tree order.
    func tiedSprites() -> [(node: SKSpriteNode, rank: CGFloat)] {
        var involved = Set<Int>()
        for (i, j) in tiePairs() { involved.insert(i); involved.insert(j) }
        var next: [CGFloat: Int] = [:]
        var out: [(node: SKSpriteNode, rank: CGFloat)] = []
        for i in involved.sorted() {
            let rank = next[sprites[i].z, default: 0]
            next[sprites[i].z] = rank + 1
            out.append((sprites[i].node, CGFloat(rank)))
        }
        return out
    }
}
