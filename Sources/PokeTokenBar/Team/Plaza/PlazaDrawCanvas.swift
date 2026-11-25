import Foundation

/// The quiz canvas: one palette index per cell, row 0 on top. Integer drawing only, so both systems draw the same cells.
struct PlazaDrawCanvas: Equatable, Sendable {
    static let width = 96, height = 64
    static let colorCount = 9                    // 0 is the paper, 1...8 the pens
    static let widths: Set<Int> = [1, 3, 5]      // thin pen, thick pen, eraser
    private(set) var cells: [UInt8]              // width * height

    init() {
        cells = [UInt8](repeating: 0, count: Self.width * Self.height)
    }

    /// 0 outside the canvas.
    subscript(x: Int, y: Int) -> UInt8 {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return 0 }
        return cells[y * Self.width + x]
    }

    /// Draws straight segments between the points with a square brush `width` cells wide, centred on the line.
    /// Nothing is drawn and false comes back when the list is empty, odd, longer than `2 * TeamDraw.maxPoints`,
    /// holds a point outside the canvas, or the colour or width is not one of the allowed values.
    @discardableResult
    mutating func stroke(points: [Int], color: Int, width: Int) -> Bool {
        guard !points.isEmpty, points.count % 2 == 0, points.count <= 2 * TeamDraw.maxPoints,
              color >= 0, color < Self.colorCount, Self.widths.contains(width) else { return false }
        for i in stride(from: 0, to: points.count, by: 2) {
            guard points[i] >= 0, points[i] < Self.width, points[i + 1] >= 0, points[i + 1] < Self.height else { return false }
        }
        let radius = (width - 1) / 2
        let value = UInt8(color)
        var x = points[0], y = points[1]
        stamp(x, y, radius, value)
        for i in stride(from: 2, to: points.count, by: 2) {
            // Bresenham with integer error terms.
            let x1 = points[i], y1 = points[i + 1]
            let dx = abs(x1 - x), dy = -abs(y1 - y)
            let sx = x < x1 ? 1 : -1, sy = y < y1 ? 1 : -1
            var err = dx + dy
            while x != x1 || y != y1 {
                let e2 = 2 * err
                if e2 >= dy { err += dy; x += sx }
                if e2 <= dx { err += dx; y += sy }
                stamp(x, y, radius, value)
            }
        }
        return true
    }

    private mutating func stamp(_ cx: Int, _ cy: Int, _ r: Int, _ value: UInt8) {
        for y in max(0, cy - r)...min(Self.height - 1, cy + r) {
            for x in max(0, cx - r)...min(Self.width - 1, cx + r) { cells[y * Self.width + x] = value }
        }
    }

    mutating func clear() {
        cells = [UInt8](repeating: 0, count: Self.width * Self.height)
    }

    /// Run-length pairs (count 1...255, colour), rows in order.
    func packed() -> Data {
        var out = Data()
        var run = 0
        var current = cells[0]
        for c in cells {
            if c == current && run < 255 { run += 1; continue }
            out.append(UInt8(run)); out.append(current)
            current = c; run = 1
        }
        out.append(UInt8(run)); out.append(current)
        return out
    }

    /// nil unless the data expands to exactly `width * height` cells of valid colours.
    init?(packed: Data) {
        let total = Self.width * Self.height
        guard packed.count % 2 == 0 else { return nil }
        var cells = [UInt8]()
        cells.reserveCapacity(total)
        let bytes = [UInt8](packed)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let count = Int(bytes[i]), color = bytes[i + 1]
            guard count > 0, Int(color) < Self.colorCount, cells.count + count <= total else { return nil }
            cells.append(contentsOf: repeatElement(color, count: count))
        }
        guard cells.count == total else { return nil }
        self.cells = cells
    }

    /// One pass over the cells into the bitmap bytes (called often while drawing).
    func bitmap(palette: [PlazaRGBA]) -> PlazaBitmap {
        precondition(palette.count == Self.colorCount, "palette needs \(Self.colorCount) colours")
        var bitmap = PlazaBitmap(width: Self.width, height: Self.height)
        var i = 0
        for c in cells {
            let p = palette[Int(c)]
            bitmap.bytes[i] = p.r; bitmap.bytes[i + 1] = p.g; bitmap.bytes[i + 2] = p.b; bitmap.bytes[i + 3] = p.a
            i += 4
        }
        return bitmap
    }
}
