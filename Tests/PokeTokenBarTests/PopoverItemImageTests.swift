import XCTest
@testable import PokeTokenBar

/// A source of item bytes with no network: the answers it is given, and how many times it was asked.
private final class FakeItemSource: PopoverItemSource, @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var answers: [String: Data]
    private var asked = 0
    init(directory: URL, answers: [String: Data]) {
        self.directory = directory
        self.answers = answers
    }
    var askedCount: Int { lock.lock(); defer { lock.unlock() }; return asked }
    func data(itemName: String) async -> Data? { answer(itemName) }
    private func answer(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        asked += 1
        return answers[name]
    }
}

/// The item sprite loader (stage 7 Task 19), the shared port of `SpriteLoader.cachedItemImage` and `itemImage`.
@MainActor
final class PopoverItemImageTests: XCTestCase {
    private func png(side: Int = 30) -> Data {
        let graphics = PlatformPlaza.graphics
        let canvas = graphics.makeCanvas(width: side, height: side, colorSpace: .sRGB)!
        canvas.setFillColor(PlazaColor(srgbRed: 1, green: 0.2, blue: 0.4))
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return graphics.encodePNG(canvas.makeImage()!)!
    }

    private func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("item-images-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override func setUp() async throws { PopoverItemImages.forgetAll() }

    func testLoadDecodesTheStoresBytesAndKeepsThePictureInMemory() async {
        let source = FakeItemSource(directory: folder(), answers: ["rare-candy": png()])
        let first = await PopoverItemImages.load(name: "rare-candy", source: source)
        XCTAssertEqual(first?.width, 30)
        let second = await PopoverItemImages.load(name: "rare-candy", source: source)
        XCTAssertTrue(first === second, "the same picture again, as the Mac's imageCache")
        XCTAssertEqual(source.askedCount, 1, "the store was asked once")
    }

    func testMissingOrBrokenBytesGiveNothing() async {
        let source = FakeItemSource(directory: folder(), answers: ["broken": Data("not a picture".utf8)])
        let none = await PopoverItemImages.load(name: "shiny-charm", source: source)
        XCTAssertNil(none, "the store has none: the icon shows its emoji")
        let broken = await PopoverItemImages.load(name: "broken", source: source)
        XCTAssertNil(broken)
    }

    func testCachedReadsTheCacheFolderWithoutAsking() async throws {
        let dir = folder()
        XCTAssertNil(PopoverItemImages.cached(name: "rare-candy", directory: dir))
        try png().write(to: dir.appendingPathComponent("item-rare-candy.png"))
        let hit = PopoverItemImages.cached(name: "rare-candy", directory: dir)
        XCTAssertNotNil(hit, "a file the store saved shows at once")
        XCTAssertTrue(PopoverItemImages.cached(name: "rare-candy", directory: dir) === hit, "then from memory")
    }

    /// Every item the shop sells names its sprite as the Mac does: the mint has none and shows its emoji.
    func testSpriteNamesAndEmojiMatchTheMacsItems() async {
        XCTAssertEqual(ItemKind.rareCandy.spriteName, "rare-candy")
        XCTAssertNil(ItemKind.mint.spriteName)
        XCTAssertEqual(ItemKind.shinyCharm.spriteName, "shiny-charm")
        for kind in ItemKind.allCases { XCTAssertFalse(kind.fallbackEmoji.isEmpty) }
    }

    func testTheIconDrawsASpriteOrTheEmoji() async {
        let graphics = PlatformPlaza.graphics
        let emoji = ItemIconPart(kind: .mint).render(scale: 2, graphics: graphics)
        XCTAssertEqual(emoji.drawing.layers.count, 1, "the emoji")
        let sprite = ItemIconPart(kind: .rareCandy, image: graphics.decodeImage(png())).render(scale: 2, graphics: graphics)
        XCTAssertEqual(sprite.drawing.layers.count, 1, "the fitted sprite")
        if case .image(_, let frame)? = sprite.drawing.layers.first { XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 30, height: 30)) }
    }
}
