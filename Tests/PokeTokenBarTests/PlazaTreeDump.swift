import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import PokeTokenBar

/// The harness's node-tree dump (one line per node, `PlazaSKTreeDump`'s format) produced from the shared tree, so a
/// Windows run, which has no SpriteKit, writes the same text the Mac harness writes for the same scene. The Mac test
/// `PlazaRenderTreeDumpTests` proves the shared dump equals the SpriteKit dump on every harness capture; the cross-OS
/// compare (stage 6, Task 15) then compares shared dumps from the two OSes.
///
/// Deterministic text: fixed number formats (4 decimals, `0` for zero), texture ordinals by first appearance, indent by
/// depth. A textured sprite ends with `tex<ordinal>:<w>x<h>#<first 16 hex of SHA-256>` of the texture's own pixels
/// (the cut, premultiplied RGBA, rows packed). The SpriteKit dump hashes the data of the texture's `CGImage` instead,
/// and a `CGImage` cut from a sheet shares the whole sheet's data, so its hash names the sheet; the Mac test
/// compares with `PlazaSKTreeDump.regionLines`, the SpriteKit dump with the cut's own pixels hashed.
@MainActor
enum PlazaTreeDump {
    /// Class names as the SpriteKit dump prints them for the nodes of a shared tree (`SKNode`, `SKSpriteNode`,
    /// `SKCropNode`, `SKCameraNode`), unless `classNames` names the node (the scene root and the layer roots keep
    /// the names their classes had before the tree was shared: `classNames(of:)`). `camera` is printed as
    /// `SKCameraNode` wherever it sits.
    static func lines(root: PlazaNode, camera: PlazaCameraNode?, classNames: [ObjectIdentifier: String] = [:]) -> [String] {
        var dump = Walker(camera: camera, classNames: classNames)
        dump.walk(root, depth: 0)
        return dump.lines
    }

    /// The names the harness has always printed for the scene's own nodes.
    static func classNames(of scene: PlazaScene) -> [ObjectIdentifier: String] {
        var out: [ObjectIdentifier: String] = [ObjectIdentifier(scene.root): "PlazaScene"]
        func add(_ node: PlazaNode?, _ name: String) { if let node { out[ObjectIdentifier(node)] = name } }
        add(scene.tallGrassLayer?.root, "PlazaTallGrassLayer")
        add(scene.pondLayer?.root, "PlazaPondLayer")
        add(scene.iceLayer?.root, "PlazaIceLayer")
        add(scene.weatherLayer.root, "PlazaWeatherLayer")
        add(scene.fireworkLayer.root, "PlazaFireworkLayer")
        add(scene.footprintLayer.root, "PlazaFootprintLayer")
        add(scene.snowballLayer.root, "PlazaSnowballLayer")
        return out
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    @MainActor private struct Walker {
        let camera: PlazaCameraNode?
        let classNames: [ObjectIdentifier: String]
        var lines: [String] = []
        var ordinals: [ObjectIdentifier: Int] = [:]
        var textureTokens: [ObjectIdentifier: String] = [:]

        init(camera: PlazaCameraNode?, classNames: [ObjectIdentifier: String]) {
            self.camera = camera
            self.classNames = classNames
        }

        func f(_ v: CGFloat) -> String {
            let r = (Double(v) * 10000).rounded() / 10000
            return r == 0 ? "0" : String(format: "%.4f", r)
        }
        func p(_ v: CGPoint) -> String { "\(f(v.x)),\(f(v.y))" }
        func s(_ v: CGSize) -> String { "\(f(v.width))x\(f(v.height))" }

        func className(_ node: PlazaNode) -> String {
            if let name = classNames[ObjectIdentifier(node)] { return name }
            if node === camera || node is PlazaCameraNode { return "SKCameraNode" }
            switch node {
            case is PlazaSprite: return "SKSpriteNode"
            case is PlazaCropNode: return "SKCropNode"
            default: return "SKNode"
            }
        }

        /// SpriteKit's `SKBlendMode.rawValue` for the three modes the plaza uses.
        func blendRaw(_ m: PlazaBlendMode) -> Int {
            switch m {
            case .alpha: 0
            case .multiply: 3
            case .multiplyX2: 4
            }
        }

        /// `SKSpriteNode.frame` rounds to 1/1000 (the crop mask sprite is the only frame the dump prints).
        func thousandths(_ v: CGFloat) -> CGFloat { CGFloat(Float((Double(v) * 1000).rounded() / 1000)) }

        mutating func texture(_ t: PlazaTexture) -> String {
            let id = ObjectIdentifier(t)
            let ordinal: Int
            if let o = ordinals[id] { ordinal = o } else { ordinal = ordinals.count; ordinals[id] = ordinal }
            if textureTokens[id] == nil {
                let image = t.image
                let x0 = Int((t.rect.minX * CGFloat(image.width)).rounded()), y0 = Int(((1 - t.rect.maxY) * CGFloat(image.height)).rounded())
                let w = Int((t.rect.width * CGFloat(image.width)).rounded()), h = Int((t.rect.height * CGFloat(image.height)).rounded())
                let part = image.pixels.cropped(to: PlazaPixelRect(x: x0, y: y0, width: w, height: h))
                textureTokens[id] = "\(part.width)x\(part.height)#" + String(PlazaTreeDump.sha256Hex(part.bytes).prefix(16))
            }
            return "tex\(ordinal):\(textureTokens[id]!)"
        }

        mutating func walk(_ node: PlazaNode, depth: Int) {
            var line = String(repeating: " ", count: depth)
                + "\(className(node)) name=\(node.name ?? "-") p=\(p(node.position)) z=\(f(node.zPosition)) a=\(f(node.alpha))"
                + " h=\(node.isHidden ? 1 : 0) sc=\(f(node.xScale)),\(f(node.yScale)) rot=\(f(node.zRotation))"
            if let sprite = node as? PlazaSprite {
                let c = sprite.color
                line += " size=\(s(sprite.size)) anchor=\(p(sprite.anchorPoint))"
                    + " color=\(f(CGFloat(c.red))),\(f(CGFloat(c.green))),\(f(CGFloat(c.blue))),\(f(CGFloat(c.alpha)))"
                    + " cbf=\(f(sprite.colorBlendFactor)) blend=\(blendRaw(sprite.blendMode))"
                if let t = sprite.texture { line += " \(texture(t))" }
            }
            if let crop = node as? PlazaCropNode {
                if let r = crop.maskRect {
                    line += " mask=SKSpriteNode p=\(p(r.origin)) frame=\(f(thousandths(r.minX))),\(f(thousandths(r.minY))),\(f(thousandths(r.width))),\(f(thousandths(r.height)))"
                } else {
                    line += " mask=nil"
                }
            }
            lines.append(line)
            for child in node.children { walk(child, depth: depth + 1) }
        }
    }
}
