import Foundation

/// Where an item sprite's bytes come from (cache file, else the download): `SpriteStore` is the real one; a test hands in a
/// fake with no network.
protocol PopoverItemSource: Sendable {
    var directory: URL { get }
    func data(itemName: String) async -> Data?
}

extension SpriteStore: PopoverItemSource {}

/// Item sprites for the popover (stage 7 Task 19): a shared port of the Mac's `SpriteLoader.cachedItemImage` and `itemImage`
/// (`UI/SpriteLoader.swift`, upstream-owned, on `NSImage`) over the same `SpriteStore` bytes and cache files (`item-<name>.png`),
/// decoded by the platform's image decoder. A sprite that is missing or fails gives nil: the icon shows the item's emoji
/// (`ItemKind.fallbackEmoji`), as the Mac's `ItemIconView`. The decoded pictures are kept in memory by file path, as the Mac's
/// `imageCache` does (main actor only).
@MainActor enum PopoverItemImages {
    private static var memory: [String: PlazaImage] = [:]

    /// The picture if it is in memory or in the cache folder, without waiting (`SpriteLoader.cachedItemImage`).
    static func cached(name: String, directory: URL, graphics: any PlazaGraphics = PlatformPlaza.graphics) -> PlazaImage? {
        let f = directory.appendingPathComponent("item-\(name).png")
        let key = f.path
        if let image = memory[key] { return image }
        if let d = try? Data(contentsOf: f), let image = graphics.decodeImage(d) {
            memory[key] = image
            return image
        }
        return nil
    }

    /// The picture, loading it when needed (`SpriteLoader.itemImage`); nil when the store has none.
    static func load(name: String, source: any PopoverItemSource = SpriteStore.shared,
                     graphics: any PlazaGraphics = PlatformPlaza.graphics) async -> PlazaImage? {
        let key = source.directory.appendingPathComponent("item-\(name).png").path
        if let image = memory[key] { return image }
        guard let d = await source.data(itemName: name) else { return nil }
        if let image = memory[key] { return image }
        guard let image = graphics.decodeImage(d) else { return nil }
        memory[key] = image
        return image
    }

    /// Forgets the pictures kept in memory (a test of the cache folder path).
    static func forgetAll() { memory = [:] }
}

/// The item icon (`ItemIconView`, 30 pt): the sprite fitted into a square box without distortion and drawn without smoothing
/// (`SpriteFit`, `.interpolation(.none)`), or the item's emoji while the sprite is not there.
@MainActor final class ItemIconPart: PopoverPart {
    var onChange: (() -> Void)?
    let kind: ItemKind
    let side: CGFloat
    private(set) var image: PlazaImage?
    private let drawing = ActivityDrawing()

    init(kind: ItemKind, side: CGFloat = 30, image: PlazaImage? = nil) {
        self.kind = kind
        self.side = side
        self.image = image
    }

    /// The sprite arrived (or went): the part is drawn again.
    func update(_ next: PlazaImage?) {
        guard next !== image else { return }
        image = next
        onChange?()
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: side, height: side) }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        var layers: [PlazaPanelLayer] = []
        if let image {
            let fit = PopoverSpriteFit.size(for: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)), box: side)
            let target = CGRect(x: (side - fit.width) / 2, y: (side - fit.height) / 2, width: fit.width, height: fit.height)
            let space = PlazaPanelSpace(content: box.size, room: 0)
            if let picture = space.image(scale: scale, graphics: graphics, { canvas in
                canvas.setInterpolationNone()
                canvas.draw(image, in: space.canvas(target))
            }) {
                layers.append(.image(picture, frame: box))
            }
        } else {
            let emoji = drawing.emoji(kind.fallbackEmoji, size: side, alpha: 1, at: .zero, scale: scale, graphics: graphics)
            if case .image(let picture, let frame)? = emoji.layer {  // centred in the box (`.frame(width: size, height: size)`)
                layers.append(.image(picture, frame: frame.offsetBy(dx: (side - frame.width) / 2, dy: (side - frame.height) / 2)))
            }
        }
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: [], tooltips: []))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}

/// One sprite slot in a square box (the egg of an `EggCard`: `SpriteView(speciesID: nil, size: 26)` in a 30 pt frame; the Bag's
/// empty state: `SpriteView(speciesID: 143, size: 96, animated: true)`), left to the host's sprite animator.
@MainActor final class SpriteBoxPart: PopoverPart {
    var onChange: (() -> Void)?
    let box: CGFloat
    let sprite: CGFloat
    private let subject: PlazaSpriteSubjectKey
    private let animated: Bool

    init(speciesID: Int?, sprite: CGFloat, box: CGFloat? = nil, animated: Bool = false) {
        self.sprite = sprite
        self.box = box ?? sprite
        self.animated = animated
        subject = PlazaSpriteSubjectKey(speciesID: speciesID)
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: box, height: box) }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let inset = (box - sprite) / 2
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: [], accessibility: [], tooltips: []),
                              spriteSlots: [SpriteSlot(frame: CGRect(x: inset, y: inset, width: sprite, height: sprite), subject: subject,
                                                       bob: false, animated: animated)])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}

/// The egg card's tier badge (`Badge(l.rarityLabel(tier).uppercased(), tint: .rarity(tier))`): the companion header's badge,
/// drawn by the same code (`CompanionHeaderPart.drawBadge`), as a part of its own, as wide as its text.
@MainActor final class BadgePart: PopoverPart {
    var onChange: (() -> Void)?
    let badge: CompanionHeaderModel.Badge

    init(_ badge: CompanionHeaderModel.Badge) { self.badge = badge }

    private func block(text: any PlazaTextEngine) -> (CompanionHeaderPart.BadgeBlock, CGSize) {
        let font = PlazaFont.system(size: 8, weight: .bold)
        let line = text.line(badge.text, font: font)
        let (height, ascender) = CompanionHeaderPart.lineHeight(font, text)
        let size = CompanionHeaderPart.badgeSize(textWidth: ceil(line.width), lineHeight: height)
        return (CompanionHeaderPart.BadgeBlock(line: line, frame: CGRect(origin: .zero, size: size), ascender: ascender, badge: badge), size)
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { block(text: text).1 }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let (b, size) = block(text: graphics.text)
        let space = PlazaPanelSpace(content: size, room: 0)
        var layers: [PlazaPanelLayer] = []
        if let picture = space.image(scale: scale, graphics: graphics, { canvas in
            CompanionHeaderPart.drawBadge(b, canvas: canvas, space: space)
        }) {
            layers.append(.image(picture, frame: b.frame))
        }
        let items = [PlazaAccessibilityItem(frame: b.frame, role: .staticText, label: badge.text)]
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: []))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
