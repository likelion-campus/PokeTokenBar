import AppKit

/// SF Symbols as plaza images (the seam `PlatformPlaza.symbolImage`): the symbol configured as the SwiftUI views configured
/// it (`Label(systemImage:)` in a 12 pt font: point size, weight, medium scale), drawn into a bitmap at `scale` in `color`.
enum MacPlazaSymbols {
    static func image(named name: String, pointSize: CGFloat, weight: PlazaFontWeight, scale: CGFloat,
                      color: PlazaColor) -> (image: PlazaImage, size: CGSize)? {
        let nsWeight: NSFont.Weight = switch weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let symbol = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: nsWeight, scale: .medium))
        else { return nil }
        let size = symbol.size
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)   // the symbol's shape in the tint
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage().map { (PlazaImage(cgImage: $0), size) }
    }
}
