import Foundation
import Observation

/// The small map at the window's bottom right (`PlazaMinimapView`, the SwiftUI view, before Track A Task 16): the plaza map
/// scaled to `PlazaMinimapModel.width`, lit like the plaza (the day's tint, the night's lower saturation; with the
/// background hidden neither, and the map and plate dim to 30 % / black 45 %), with the view's rectangle, the campfire's
/// square, the item's diamond and a dot per member on it. It takes no clicks.
///
/// Two layers: the plate with the map (made again only when the minute, the season's map, the hidden background or the
/// backing scale changes; the downscaled map is kept per season image and scale) and the marks (made again when a dot, the
/// view rectangle, the campfire or the item changes).
@MainActor final class PlazaMinimapPanel: PlazaPanel {
    let id = PlazaPanelID.minimap
    let anchor = PlazaPanelAnchor.bottomTrailing
    let offset: CGPoint
    var onChange: (() -> Void)?
    private let model: PlazaMinimapModel
    private let background: PlazaBackgroundModel
    private let mapImage: () -> PlazaImage
    private let worldSize: CGSize
    private var observer: PlazaChangeObserver?

    static let dimmedMapOpacity = 0.3, dimmedPanelOpacity = 0.45
    private static let dark = PlazaColor(hex: 0x14161F)

    /// The minute of the day the map is lit for (the window's clock updates it every second; it changes once a minute).
    private(set) var minute = 0

    /// How often each part was made (tests and the idle check).
    private(set) var plateRenders = 0, marksRenders = 0, mapScalings = 0

    init(model: PlazaMinimapModel, background: PlazaBackgroundModel, worldSize: CGSize, mapImage: @escaping () -> PlazaImage) {
        self.model = model
        self.background = background
        self.worldSize = worldSize
        self.mapImage = mapImage
        let room = PlazaPanelStyle.strokeRoom
        offset = CGPoint(x: PlazaRosterMetrics.margin - room, y: PlazaPanelStyle.minimapBottom - room)
        observer = PlazaChangeObserver(track: {
            _ = model.dots; _ = model.view; _ = model.item; _ = model.campfire; _ = model.coreTime; _ = model.seasonMapImage
            _ = background.isHidden
        }, changed: { [weak self] in self?.modelChanged() })
    }

    private struct State: Equatable {
        let dots: [PlazaMinimapModel.Dot], view: CGRect, item: TilePoint?, campfire: TilePoint?, core: PlazaCoreTime
        let season: ObjectIdentifier?, hidden: Bool, minute: Int
    }
    private var state: State {
        State(dots: model.dots, view: model.view, item: model.item, campfire: model.campfire, core: model.coreTime,
              season: model.seasonMapImage.map(ObjectIdentifier.init), hidden: background.isHidden, minute: background.isHidden ? 0 : minute)
    }
    private var rendered: State?
    private func modelChanged() { if rendered != state { onChange?() } }

    /// The window's clock, once a second: the map's lighting follows the minute.
    func update(date: Date) {
        let m = Int(PlazaDaylight.minute(of: date).rounded(.down))
        guard m != minute else { return }
        minute = m
        if !background.isHidden { onChange?() }
    }

    var isVisible: Bool { true }
    private var mapHeight: CGFloat { (PlazaMinimapModel.width * worldSize.height / max(worldSize.width, 1)).rounded() }
    private var content: CGSize { CGSize(width: PlazaMinimapModel.width + 8, height: mapHeight + 8) }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { PlazaPanelSpace(content: content).size }

    // MARK: the plate and map

    private var scaled: (key: String, bitmap: PlazaBitmap)?
    private var plate: (key: String, image: PlazaImage)?

    private func plateImage(scale: CGFloat, graphics: any PlazaGraphics) -> PlazaImage? {
        let hidden = background.isHidden
        let source = model.seasonMapImage ?? mapImage()
        let core = model.coreTime
        let key = "\(ObjectIdentifier(source).hashValue) \(scale) \(hidden) \(hidden ? 0 : minute) \(core.start) \(core.end)"
        if let plate, plate.key == key { return plate.image }
        let w = Int((PlazaMinimapModel.width * scale).rounded()), h = Int((mapHeight * scale).rounded())
        let scalingKey = "\(ObjectIdentifier(source).hashValue) \(scale)"
        var map: PlazaBitmap
        if let scaled, scaled.key == scalingKey { map = scaled.bitmap } else {
            map = PlazaMinimapPixels.downscaled(source.pixels, width: w, height: h)
            scaled = (scalingKey, map)
            mapScalings += 1
        }
        if !hidden {
            map = PlazaMinimapPixels.tinted(map, tint: PlazaDaylight.tint(minute: Double(minute), core: core),
                                            saturation: PlazaDaylight.minimapSaturation(minute: Double(minute), core: core))
        }
        let space = PlazaPanelSpace(content: content)
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            canvas.setFillColor(hidden ? PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: Self.dimmedPanelOpacity) : PlazaColor(hex: 0x1D4F5C))
            canvas.fillRoundedRect(space.canvas(CGRect(origin: .zero, size: self.content)), radius: 6)
            canvas.saveState()
            canvas.clip(toRoundedRect: space.canvas(CGRect(x: 4, y: 4, width: PlazaMinimapModel.width, height: self.mapHeight)), radius: 3)
            if hidden { canvas.setAlpha(Self.dimmedMapOpacity) }
            canvas.draw(PlazaImage(bitmap: map), in: space.canvas(CGRect(x: 4, y: 4, width: PlazaMinimapModel.width, height: self.mapHeight)))
            canvas.restoreState()
            canvas.setStrokeColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: hidden ? 0.3 : 0.5))
            canvas.strokeRoundedRect(space.canvas(CGRect(origin: .zero, size: self.content)), radius: 6, lineWidth: 1.5)
        }
        if let image { plate = (key, image) }
        plateRenders += 1
        return image
    }

    // MARK: the marks

    private func marksImage(scale: CGFloat, graphics: any PlazaGraphics) -> PlazaImage? {
        marksRenders += 1
        let width = PlazaMinimapModel.width
        let space = PlazaPanelSpace(content: CGSize(width: width, height: mapHeight), room: 0)
        let s = width / max(worldSize.width, 1)
        let tile = CGFloat(PlazaMap.tileSize) * s
        let view = model.view
        // A 1-pt line sits on the pixel grid as SwiftUI drew it: an odd number of device pixels is centred on a pixel's middle,
        // an even one on a pixel edge (at 1x a line on a pixel edge would be two half-bright pixels).
        func crisp(_ v: CGFloat) -> CGFloat {
            if scale != 1 { return v }
            let d = v * scale
            return (Int((1 * scale).rounded()) % 2 == 1 ? d.rounded(.down) + 0.5 : d.rounded()) / scale
        }
        func crisp(_ r: CGRect) -> CGRect {
            let x0 = crisp(r.minX), y0 = crisp(r.minY)
            return CGRect(x: x0, y: y0, width: crisp(r.maxX) - x0, height: crisp(r.maxY) - y0)
        }
        return space.image(scale: scale, graphics: graphics) { canvas in
            canvas.clip(toRoundedRect: space.canvas(CGRect(origin: .zero, size: space.size)), radius: 3)
            func c(_ p: CGPoint) -> CGPoint { space.canvas(p) }
            func rect(_ r: CGRect) -> CGRect { space.canvas(r) }
            if view.width > 0 {
                canvas.setStrokeColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
                canvas.strokePath(PlazaPath(rect: rect(crisp(CGRect(x: view.minX * s, y: view.minY * s, width: view.width * s, height: view.height * s)))),
                                  lineWidth: 1, cap: .butt)
            }
            if let fire = model.campfire {
                // 모닥불 자리는 2×2칸이라 중심은 왼쪽 위 칸에서 한 칸 오른쪽·아래다.
                let ctr = CGPoint(x: (CGFloat(fire.x) + 1) * tile, y: (CGFloat(fire.y) + 1) * tile)
                let square = rect(CGRect(x: ctr.x - 2.5, y: ctr.y - 2.5, width: 5, height: 5))
                canvas.setFillColor(PlazaColor(hex: 0xF08A24))
                canvas.fillPath(PlazaPath(rect: square))
                canvas.setStrokeColor(Self.dark)
                canvas.strokePath(PlazaPath(rect: rect(crisp(CGRect(x: ctr.x - 2.5, y: ctr.y - 2.5, width: 5, height: 5)))), lineWidth: 1, cap: .butt)
            }
            if let item = model.item {
                let ctr = CGPoint(x: (CGFloat(item.x) + 0.5) * tile, y: (CGFloat(item.y) + 0.5) * tile)
                let diamond = PlazaPath(points: [c(CGPoint(x: ctr.x, y: ctr.y - 4)), c(CGPoint(x: ctr.x + 4, y: ctr.y)),
                                                 c(CGPoint(x: ctr.x, y: ctr.y + 4)), c(CGPoint(x: ctr.x - 4, y: ctr.y))], closed: true)
                canvas.setFillColor(PlazaColor(hex: 0xF2C14E))
                canvas.fillPath(diamond)
                canvas.setStrokeColor(Self.dark)
                canvas.setLineJoin(.miter)
                canvas.strokePath(diamond, lineWidth: 1, cap: .butt)
            }
            for dot in model.dots.sorted(by: { !$0.isMe && $1.isMe }) {
                let r: CGFloat = dot.isMe ? 4.5 : 3.5
                let ctr = CGPoint(x: (CGFloat(dot.tile.x) + 0.5) * tile, y: (CGFloat(dot.tile.y) + 0.5) * tile)
                let circle = rect(CGRect(x: ctr.x - r, y: ctr.y - r, width: r * 2, height: r * 2))
                canvas.saveState()
                canvas.setAlpha(dot.isAway ? 0.45 : 1)
                canvas.setFillColor(dot.color)
                canvas.fillEllipse(in: circle)
                canvas.setStrokeColor(dot.isMe ? .white : Self.dark)
                canvas.strokeEllipse(in: circle, lineWidth: dot.isMe ? 1.5 : 1)
                canvas.restoreState()
            }
        }
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        var layers: [PlazaPanelLayer] = []
        let space = PlazaPanelSpace(content: content)
        if let plate = plateImage(scale: scale, graphics: graphics) { layers.append(.image(plate, frame: CGRect(origin: .zero, size: space.size))) }
        if let marks = marksImage(scale: scale, graphics: graphics) {
            layers.append(.image(marks, frame: space.panel(CGRect(x: 4, y: 4, width: PlazaMinimapModel.width, height: mapHeight))))
        }
        return PlazaPanelDrawing(layers: layers)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
