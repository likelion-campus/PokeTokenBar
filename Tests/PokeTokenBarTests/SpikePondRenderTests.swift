import XCTest
import SpriteKit
import Metal
@testable import PokeTokenBar

/// Throwaway (spec §9 experiment 4). Renders the pond layer offscreen and times its update loop.
/// Runs only when PTB_SPIKE_OUT names a directory.
@MainActor
final class SpikePondRenderTests: XCTestCase {
    private func script(_ layer: PlazaPondLayer, frame: Int) {
        if frame % 20 == 0 { layer.splash(at: TilePoint(x: 5 + (frame / 20) % 6, y: 8), big: (frame / 20) % 2 == 0) }
        if frame % 7 == 0 { layer.bubble(at: TilePoint(x: 8, y: 6 + (frame / 7) % 4)) }
        layer.update(dt: 1.0 / 60)
    }

    private func render(_ scene: SKScene, renderer: SKRenderer, queue: MTLCommandQueue, target: MTLTexture, t: TimeInterval) -> [UInt8] {
        let size = CGSize(width: target.width, height: target.height)
        for pass in 0..<15 {
            scene.size = size; renderer.update(atTime: t + Double(pass) / 60); scene.size = size
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = .clear
            d.colorAttachments[0].storeAction = .store
            let buffer = queue.makeCommandBuffer()!
            renderer.render(withViewport: CGRect(origin: .zero, size: size), commandBuffer: buffer, renderPassDescriptor: d)
            buffer.commit(); buffer.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return bytes
    }

    private func dump(_ node: SKNode, depth: Int = 0) -> String {
        var line = String(repeating: " ", count: depth)
            + "\(type(of: node)) p=\(node.position) z=\(node.zPosition) a=\(node.alpha) h=\(node.isHidden)"
        if let s = node as? SKSpriteNode { line += " size=\(s.size) tex=\(s.texture.map { "\($0.size())" } ?? "nil") blend=\(s.blendMode.rawValue)" }
        return ([line] + node.children.map { dump($0, depth: depth + 1) }).joined(separator: "\n")
    }

    func testRenderAndTime() throws {
        guard let out = ProcessInfo.processInfo.environment["PTB_SPIKE_OUT"] else { throw XCTSkip("PTB_SPIKE_OUT not set") }
        let dir = URL(fileURLWithPath: out); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 480, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = SKRenderer(device: device)

        // Three conditions: plain water, a multiply night tint above, and a x2 light above.
        for (name, blend, colour) in [("noon", SKBlendMode.alpha, SKColor.clear),
                                      ("night", SKBlendMode.multiply, SKColor(red: 0.35, green: 0.4, blue: 0.7, alpha: 1)),
                                      ("fire", SKBlendMode.multiplyX2, SKColor(red: 0.8, green: 0.6, blue: 0.4, alpha: 1))] {
            let scene = SKScene(size: CGSize(width: 640, height: 480))
            scene.backgroundColor = PlazaPondArt.waterColor
            scene.anchorPoint = .zero
            let water = SKSpriteNode(color: PlazaPondArt.waterColor, size: scene.size)
            water.anchorPoint = .zero; water.zPosition = -1
            scene.addChild(water)
            let layer = PlazaPondLayer()
            let host = SKNode()
            host.position = CGPoint(x: 0, y: -560)   // bring the scripted tiles into view
            host.addChild(SpikePondHost.node(of: layer))
            scene.addChild(host)
            let tint = SKSpriteNode(color: colour, size: scene.size)
            tint.anchorPoint = .zero; tint.zPosition = 100; tint.blendMode = blend
            scene.addChild(tint)
            renderer.scene = scene
            for (index, stop) in [15, 47, 133].enumerated() {
                let from = index == 0 ? 0 : [15, 47, 133][index - 1]
                for frame in from..<stop { script(layer, frame: frame) }
                let bytes = render(scene, renderer: renderer, queue: queue, target: target, t: Double(stop) / 60)
                try Data(bytes).write(to: dir.appendingPathComponent("\(name)-\(stop).bgra"))
                try dump(host).write(to: dir.appendingPathComponent("\(name)-\(stop).tree.txt"), atomically: true, encoding: .utf8)
            }
        }

        var medians: [Double] = []
        for _ in 0..<5 {
            let layer = PlazaPondLayer()
            let clock = ContinuousClock()
            let took = clock.measure { for frame in 0..<6000 { script(layer, frame: frame) } }
            medians.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1e3)
        }
        medians.sort()
        try "6000 frames, 5 runs, ms sorted: \(medians)\n".write(to: dir.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
    }
}

enum SpikePondHost {
    @MainActor static func node(of layer: PlazaPondLayer) -> SKNode { layer }
}
