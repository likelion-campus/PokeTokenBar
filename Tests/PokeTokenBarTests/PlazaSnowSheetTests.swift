import XCTest
import CoreGraphics
@testable import PokeTokenBar

final class PlazaSnowSheetTests: XCTestCase {
    private struct Pixels {
        let width: Int, height: Int
        var bytes: [UInt8]
        init(_ image: CGImage) {
            width = image.width; height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            data.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            bytes = data
        }
        init(width: Int, height: Int) {
            self.width = width; self.height = height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
        }
        func rgba(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
        mutating func set(_ x: Int, _ y: Int, _ v: [UInt8]) {
            for k in 0..<4 { bytes[(y * width + x) * 4 + k] = v[k] }
        }
        /// Opaque pixels of one colour inside a 16-px cell.
        func count(_ rgb: UInt32, cell: (col: Int, row: Int)) -> Int {
            var n = 0
            for y in cell.row * 16..<cell.row * 16 + 16 {
                for x in cell.col * 16..<cell.col * 16 + 16 {
                    let p = rgba(x, y)
                    let v: UInt32 = (UInt32(p[0]) << 16) | (UInt32(p[1]) << 8) | UInt32(p[2])
                    if p[3] == 255, v == rgb { n += 1 }
                }
            }
            return n
        }
        func count(_ rgb: UInt32) -> Int {
            var n = 0
            for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] == 255 {
                let v: UInt32 = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8) | UInt32(bytes[i + 2])
                if v == rgb { n += 1 }
            }
            return n
        }
        func cellBytes(_ cell: (col: Int, row: Int)) -> [UInt8] {
            var out: [UInt8] = []
            for y in cell.row * 16..<cell.row * 16 + 16 {
                let start: Int = (y * width + cell.col * 16) * 4
                out += bytes[start..<(start + 64)]
            }
            return out
        }
        func image() -> CGImage {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)!
        }
    }

    func testColorTablesAreTheSpecs() {
        let ground: PlazaSnowSheet.Colors = [0x3ABE41: 0xC6DAF0, 0x6ADD4B: 0xE8F0FA, 0x328E41: 0xB2C7E0,
                                             0x29973B: 0x9FC3E6, 0x315740: 0x8DA3BF]
        XCTAssertEqual(PlazaSnowSheet.groundColors, ground)
        XCTAssertEqual(PlazaSnowSheet.shoreColors, ground.merging([0x266433: 0x8DA3BF]) { $1 })
        XCTAssertEqual(PlazaSnowSheet.flowerColors, [0xE8F8D0: 0xF6FAFF, 0x328E41: 0xC6DAF0, 0x60D0C0: 0x9FC3E6])
        XCTAssertEqual(PlazaSnowSheet.bushColors, [0x2ECA35: 0xE8F0FA, 0x62EB3D: 0xF6FAFF, 0x29973B: 0xB2C7E0])
        XCTAssertEqual(PlazaSnowSheet.treeColors,
                       [0x2ECA5C: 0xE8F0FA, 0x50EB6C: 0xF6FAFF, 0x299750: 0xC6DAF0, 0x328E53: 0xC6DAF0])
        XCTAssertEqual(PlazaSnowSheet.signColors, [0x2ECA35: 0xE8F0FA, 0x29973B: 0xB2C7E0])
        XCTAssertEqual(PlazaSnowSheet.tallGrassColors, [0x99E550: 0xF6FAFF, 0x6ABE30: 0xC6DAF0])
    }

    func testShoreCellsListEveryCellTheShoreRuleDraws() {
        var seen = Set<String>()
        for mask in 0..<256 {
            let water = Set((0..<8).filter { mask & (1 << $0) != 0 })
            let offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            let wet = Set(water.map { TilePoint(x: 1 + offsets[$0].0, y: 1 + offsets[$0].1) })
            if case .cell(let c, let r) = PlazaPond.shore(at: TilePoint(x: 1, y: 1), isWater: { wet.contains($0) }) {
                XCTAssertTrue(PlazaPond.shoreCells.contains { $0.col == c && $0.row == r }, "\(c),\(r)")
                seen.insert("\(c),\(r)")
            }
        }
        XCTAssertEqual(PlazaPond.shoreCells.count, 12)
        XCTAssertEqual(seen, Set(PlazaPond.shoreCells.map { "\($0.col),\($0.row)" }))
    }

    func testRecolourSwapsOnlyListedColoursOfOpaquePixelsInsideListedCells() {
        var px = Pixels(width: 32, height: 16)
        px.set(0, 0, [0x3A, 0xBE, 0x41, 255])
        px.set(1, 0, [0x33, 0x1F, 0x29, 255])
        px.set(2, 0, [0x1D, 0x5F, 0x20, 128])   // 50 % alpha #3ABE41, premultiplied
        px.set(3, 0, [0, 0, 0, 0])
        px.set(16, 0, [0x3A, 0xBE, 0x41, 255])
        let out = Pixels(PlazaSnowSheet.recolored(px.image(), pieces: [(PlazaSnowSheet.groundColors, [(0, 0)])]))
        XCTAssertEqual(out.width, 32); XCTAssertEqual(out.height, 16)
        XCTAssertEqual(out.rgba(0, 0), [0xC6, 0xDA, 0xF0, 255])
        XCTAssertEqual(out.rgba(1, 0), [0x33, 0x1F, 0x29, 255])
        XCTAssertEqual(out.rgba(2, 0), px.rgba(2, 0))
        XCTAssertEqual(out.rgba(3, 0), [0, 0, 0, 0])
        XCTAssertEqual(out.rgba(16, 0), [0x3A, 0xBE, 0x41, 255])
    }

    func testSnowTilesKeepWaterLiliesAndEveryAlpha() throws {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
        let before = Pixels(sheet), after = Pixels(PlazaSnowSheet.tiles(sheet))
        XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
        for cell in [(3, 7), (2, 0), (4, 0), (5, 0)] {
            XCTAssertEqual(before.cellBytes(cell), after.cellBytes(cell), "\(cell)")
        }
        for i in stride(from: 3, to: before.bytes.count, by: 4) {
            if before.bytes[i] != after.bytes[i] { XCTFail("alpha differs at \(i / 4)"); break }
        }
        XCTAssertEqual(after.count(0x3ABE41, cell: (0, 9)), 0)
        XCTAssertGreaterThan(after.count(0xC6DAF0, cell: (0, 9)), 0)
        XCTAssertEqual(after.count(0x2D5B43, cell: (5, 17)), before.count(0x2D5B43, cell: (5, 17)))
        XCTAssertEqual(after.count(0x885040, cell: (34, 2)), before.count(0x885040, cell: (34, 2)))
    }

    func testSnowTallGrassKeepsTheDarkBladesAndOutline() throws {
        let sheet = try XCTUnwrap(PlazaResources.tallGrassSheet())
        let before = Pixels(sheet), after = Pixels(PlazaSnowSheet.tallGrass(sheet))
        XCTAssertEqual(after.count(0x99E550), 0)
        XCTAssertEqual(after.count(0x6ABE30), 0)
        XCTAssertEqual(after.count(0x4B692F), before.count(0x4B692F))
        XCTAssertEqual(after.count(0x222034), before.count(0x222034))
        XCTAssertNotNil(PlazaTallGrassArt(sheet: PlazaSnowSheet.tallGrass(sheet)))
    }
}
