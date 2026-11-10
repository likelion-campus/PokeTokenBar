import CoreGraphics
import Foundation
import ImageIO

/// 기념사진에 찍히는 캐릭터 하나. 좌표는 월드 픽셀이고 y가 아래로 늘어난다.
struct PlazaPhotoActor {
    let image: CGImage
    let flipped: Bool
    /// 발(그림 아래 가운데). 통통 튐은 빼고 둔다. 앞뒤 순서는 이 값으로 정한다.
    let foot: CGPoint
    /// 걸을 때 그림만 위로 들리는 월드 픽셀. 순서에는 쓰지 않는다.
    var bob: CGFloat = 0
    /// 월드 단위로 키우는 배율(1.5).
    let scale: CGFloat
    let shadow: CGImage?
    /// 그림자 사각형(월드, y 아래로).
    let shadowRect: CGRect
    /// 알 앞에 얹는 둥지 앞 테두리. 그림자와 같은 사각형에 그림 바로 다음에 그린다.
    var front: CGImage? = nil
    /// 배율 2로 만든 이름표와 말풍선. 사진 픽셀 그대로 얹는다.
    let plate: CGImage?
    let bubble: CGImage?
    /// 풀숲에 가려진 만큼 흐리게. 그림·그림자·둥지 앞 테두리에만 주고 이름표와 말풍선은 늘 불투명하다.
    var opacity: CGFloat = 1
    /// 이름표 바닥의 월드 y(아래로). nil이면 머리 위에 둔다.
    var plateBaseY: CGFloat? = nil
    /// 헤엄으로 물에 잠긴 월드 픽셀. 0보다 크면 그림을 그만큼 내려 그리고 발 선 아래는 자르며, 그림자와 둥지 앞 테두리는 그리지 않는다.
    var sink: CGFloat = 0
    /// 헤엄칠 때 발이 선 연못 사각형(월드, y 아래로). 잠긴 아랫부분을 이 안에만 반투명하게 그린다. nil이면 그리지 않는다.
    var waterClip: CGRect? = nil
    /// 물에 든 알. `sink`는 0이고, 그림을 제자리에서 통째로 물빛 반투명(`submergedEggAlpha`)으로만 연못 안에 그린다(불투명 몸통 없음).
    var eggSunk = false
    /// 춤으로 그림이 뜬 월드 픽셀. `bob`처럼 그림만 올리고 앞뒤 순서에는 쓰지 않는다.
    var lift: CGFloat = 0
    /// 춤으로 발을 기준으로 세로로 눌리거나 늘어난 배율.
    var squash: CGFloat = 1
    /// 춤으로 발(그림 아래 가운데)을 축으로 기운 라디안. 양수는 반시계 방향.
    var tilt: CGFloat = 0
}

/// 기념사진에 찍히는 풀숲 앞 띠 한 칸. 좌표는 월드 픽셀이고 y가 아래로 늘어난다.
struct PlazaPhotoBand {
    let image: CGImage
    let origin: CGPoint
    let size: CGSize
    /// 캐릭터의 `foot.y` 와 견주는 앞뒤 키(칸 맨 아래 줄).
    let sortY: CGFloat
}

/// 기념사진에 찍히는 날씨 입자 하나. 좌표는 월드 픽셀이고 y가 아래로 늘어난다(원점은 그림의 왼쪽 위).
struct PlazaPhotoParticle {
    let image: CGImage
    let origin: CGPoint
    let size: CGSize
}

/// 캐릭터와 같은 앞뒤 순서로 찍히는 물건(모닥불). `baseY`는 바닥 변의 월드 y로, 발 y가 이보다 작은 캐릭터는 뒤에 찍힌다.
struct PlazaPhotoProp {
    let particle: PlazaPhotoParticle
    let baseY: CGFloat
}

struct PlazaPhotoInput {
    let mapImage: CGImage
    /// 사진에 담을 월드 영역.
    let visibleRect: CGRect
    /// 월드 픽셀 하나가 차지하는 사진 픽셀(화면 배율 × 2).
    let pixelsPerWorld: Int
    var actors: [PlazaPhotoActor]
    /// 낮과 밤의 색. 화면처럼 지도와 캐릭터에만 곱하고 이름표와 말풍선에는 곱하지 않는다.
    var tint: PlazaDaylight.Tint = .none
    /// 화면에 떠 있는 날씨 입자. 캐릭터 위, 낮밤 색 아래라 지도와 같은 색이 곱해진다.
    var weather: [PlazaPhotoParticle] = []
    /// 땅에 떨어진 아이템. 그림자 위, 캐릭터 아래.
    var items: [PlazaPhotoParticle] = []
    /// 풀숲 앞 띠. 캐릭터와 `foot.y`/`sortY` 키 순서로 섞어 그린다.
    var bands: [PlazaPhotoBand] = []
    /// 캐릭터와 앞뒤를 겨루는 물건. 발 y가 같으면 물건이 뒤.
    var props: [PlazaPhotoProp] = []
    /// 모닥불이 던지는 밤빛. 낮밤 색 바로 위에 곱하고 이름표와 말풍선에는 곱하지 않는다.
    var light: PlazaPhotoLight?
    /// 하늘의 불꽃 조각. 빛이라 낮밤 색이 곱해지지 않고, 이름표와 말풍선 아래에 찍힌다.
    var fireworks: [PlazaPhotoParticle] = []
    /// 불꽃이 던지는 빛. 모닥불빛 다음에 곱한다.
    var fireworkLight: PlazaPhotoLight?
}

/// 기념사진에 곱할 모닥불빛. 좌표는 월드 픽셀(y 아래로)이고 반지름은 깜빡임이 이미 곱해져 있다.
struct PlazaPhotoLight {
    let center: CGPoint
    let radii: CGSize
    let tint: PlazaDaylight.Tint
    var color: (r: Double, g: Double, b: Double) = PlazaCampfireLight.warm
    /// 빛의 세기(0~1). 불꽃이 터진 뒤 줄어든다.
    var level = 1.0
}

/// 기념사진을 CoreGraphics로 합성한다. 창이나 SKView가 필요 없고, 모든 그림은 보간 없이 정수 배율로 찍는다.
enum PlazaPhotoRenderer {
    /// 지도 밖은 지도 가장자리 숲과 같은 짙은 초록.
    private static let outsideColor = CGColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1)
    private static let maxSide = 16_384
    /// 이름표는 스프라이트 머리에서 2픽셀(배율 2의 1포인트) 띄운다.
    private static let plateGap = 2

    static func render(_ input: PlazaPhotoInput) -> CGImage? {
        let ppw = CGFloat(input.pixelsPerWorld)
        let rect = input.visibleRect
        guard input.pixelsPerWorld > 0, rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        let width = Int((rect.width * ppw).rounded()), height = Int((rect.height * ppw).rounded())
        guard width > 0, height > 0, width <= maxSide, height <= maxSide,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        /// 위에서 아래로 센 사진 픽셀 사각형을 CoreGraphics 사각형으로 바꾼다.
        func cg(_ x: Int, _ top: Int, _ w: Int, _ h: Int) -> CGRect {
            CGRect(x: x, y: height - top - h, width: w, height: h)
        }
        func px(_ world: CGFloat, origin: CGFloat) -> Int { Int(((world - origin) * ppw).rounded()) }
        func draw(_ image: CGImage, x: Int, top: Int, w: Int, h: Int, mirrored: Bool = false) {
            let dest = cg(x, top, w, h)
            if mirrored {
                context.saveGState()
                context.translateBy(x: dest.midX, y: 0)
                context.scaleBy(x: -1, y: 1)
                context.translateBy(x: -dest.midX, y: 0)
                context.draw(image, in: dest)
                context.restoreGState()
            } else {
                context.draw(image, in: dest)
            }
        }

        context.setFillColor(outsideColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(input.mapImage, x: px(0, origin: rect.minX), top: px(0, origin: rect.minY),
             w: Int((CGFloat(input.mapImage.width) * ppw).rounded()), h: Int((CGFloat(input.mapImage.height) * ppw).rounded()))

        for a in input.actors {
            guard let shadow = a.shadow, a.sink <= 0, !a.eggSunk else { continue }
            context.setAlpha(a.opacity)
            defer { context.setAlpha(1) }
            draw(shadow, x: px(a.shadowRect.minX, origin: rect.minX), top: px(a.shadowRect.minY, origin: rect.minY),
                 w: Int((a.shadowRect.width * ppw).rounded()), h: Int((a.shadowRect.height * ppw).rounded()))
        }

        for p in input.items {
            draw(p.image, x: px(p.origin.x, origin: rect.minX), top: px(p.origin.y, origin: rect.minY),
                 w: Int((p.size.width * ppw).rounded()), h: Int((p.size.height * ppw).rounded()))
        }

        // 화면 위쪽에 선(발의 y가 작은) 캐릭터부터. 같으면 입력 순서를 지킨다.
        let ordered = input.actors.enumerated().sorted { ($0.element.foot.y, $0.offset) < ($1.element.foot.y, $1.offset) }.map(\.element)
        var pendingProps = input.props.sorted { $0.baseY < $1.baseY }[...]
        func drawProps(upTo y: CGFloat?) {
            while let prop = pendingProps.first, y.map({ prop.baseY <= $0 }) ?? true {
                pendingProps = pendingProps.dropFirst()
                let p = prop.particle
                draw(p.image, x: px(p.origin.x, origin: rect.minX), top: px(p.origin.y, origin: rect.minY),
                     w: Int((p.size.width * ppw).rounded()), h: Int((p.size.height * ppw).rounded()))
            }
        }
        func drawActor(_ a: PlazaPhotoActor) {
            let w = Int((CGFloat(a.image.width) * a.scale * ppw).rounded()), h = Int((CGFloat(a.image.height) * a.scale * ppw).rounded())
            context.setAlpha(a.opacity)
            defer { context.setAlpha(1) }
            let footTop = px(a.foot.y - a.bob - a.lift, origin: rect.minY)
            let sunk = a.sink > 0
            if a.eggSunk {
                if let pond = a.waterClip, let tinted = Self.submerged(a.image) {
                    let x0 = px(pond.minX, origin: rect.minX), x1 = px(pond.maxX, origin: rect.minX)
                    let y0 = px(pond.minY, origin: rect.minY), y1 = px(pond.maxY, origin: rect.minY)
                    if x1 > x0, y1 > y0 {
                        context.saveGState()
                        context.clip(to: cg(x0, y0, x1 - x0, y1 - y0))
                        context.setAlpha(a.opacity * PlazaPondArt.submergedEggAlpha)
                        // 연못 맨 윗줄에서는 화면처럼 꼭대기가 연못 위 가장자리에 닿도록 알 전체를 내려 그린다(자르지 않는다).
                        draw(tinted, x: px(a.foot.x - CGFloat(a.image.width) * a.scale / 2, origin: rect.minX), top: max(footTop - h, y0), w: w, h: h, mirrored: a.flipped)
                        context.restoreGState()
                    }
                }
                return
            }
            if sunk, let pond = a.waterClip, let tinted = Self.submerged(a.image) {
                // 잠긴 아랫부분: 화면처럼 연못 안, 발 선 아래만 반투명한 물빛으로.
                let x0 = px(pond.minX, origin: rect.minX), x1 = px(pond.maxX, origin: rect.minX)
                let y0 = max(px(pond.minY, origin: rect.minY), footTop), y1 = px(pond.maxY, origin: rect.minY)
                if x1 > x0, y1 > y0 {
                    context.saveGState()
                    context.clip(to: cg(x0, y0, x1 - x0, y1 - y0))
                    context.setAlpha(a.opacity * PlazaPondArt.submergedAlpha)
                    draw(tinted, x: px(a.foot.x - CGFloat(a.image.width) * a.scale / 2, origin: rect.minX),
                         top: footTop - h + Int((a.sink * ppw).rounded()), w: w, h: h, mirrored: a.flipped)
                    context.restoreGState()
                    context.setAlpha(a.opacity)
                }
            }
            if sunk {
                // 헤엄: 그림을 sink만큼 내려 그리고 발 선 아래는 자른다(화면이 그림 아래를 잘라 내는 것과 같다).
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: height - footTop, width: width, height: footTop))
            }
            let bodyX = px(a.foot.x - CGFloat(a.image.width) * a.scale / 2, origin: rect.minX)
            let bodyTop = footTop - h + Int((a.sink * ppw).rounded())
            // 춤: 화면처럼 발 한가운데를 축으로 기울이고 세로로 늘인다.
            let tilted = a.tilt != 0 || a.squash != 1
            if tilted {
                let pivot = CGPoint(x: CGFloat(bodyX) + CGFloat(w) / 2, y: CGFloat(height - (bodyTop + h)))
                context.saveGState()
                context.translateBy(x: pivot.x, y: pivot.y)
                context.rotate(by: a.tilt)
                context.scaleBy(x: 1, y: a.squash)
                context.translateBy(x: -pivot.x, y: -pivot.y)
            }
            draw(a.image, x: bodyX, top: bodyTop, w: w, h: h, mirrored: a.flipped)
            if tilted { context.restoreGState() }
            if sunk { context.restoreGState() }
            if let front = a.front, !sunk {
                draw(front, x: px(a.shadowRect.minX, origin: rect.minX), top: px(a.shadowRect.minY, origin: rect.minY),
                     w: Int((a.shadowRect.width * ppw).rounded()), h: Int((a.shadowRect.height * ppw).rounded()))
            }
        }
        // 풀숲 띠는 캐릭터와 키 순서로 섞는다. 같은 키면 캐릭터가 먼저라 띠가 발을 덮는다.
        let bands = input.bands.enumerated().sorted { ($0.element.sortY, $0.offset) < ($1.element.sortY, $1.offset) }.map(\.element)
        var nextBand = 0
        func drawBand(_ b: PlazaPhotoBand) {
            draw(b.image, x: px(b.origin.x, origin: rect.minX), top: px(b.origin.y, origin: rect.minY),
                 w: Int((b.size.width * ppw).rounded()), h: Int((b.size.height * ppw).rounded()))
        }
        for a in ordered {
            drawProps(upTo: a.foot.y)
            while nextBand < bands.count, bands[nextBand].sortY < a.foot.y { drawBand(bands[nextBand]); nextBand += 1 }
            drawActor(a)
        }
        while nextBand < bands.count { drawBand(bands[nextBand]); nextBand += 1 }

        drawProps(upTo: nil)

        for p in input.weather {
            draw(p.image, x: px(p.origin.x, origin: rect.minX), top: px(p.origin.y, origin: rect.minY),
                 w: Int((p.size.width * ppw).rounded()), h: Int((p.size.height * ppw).rounded()))
        }

        if input.tint != .none {
            let t = input.tint
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setFillColor(CGColor(srgbRed: t.red, green: t.green, blue: t.blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }

        for light in [input.light, input.fireworkLight].compactMap({ $0 }) {
            guard let base = context.data else { break }
            let bytes = base.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
            let n = PlazaCampfireLight.blockCounts(radii: light.radii)
            let left = light.center.x - CGFloat(n.w), top = light.center.y - CGFloat(n.h)
            for j in 0..<n.h {
                let y0 = max(px(top + CGFloat(2 * j), origin: rect.minY), 0), y1 = min(px(top + CGFloat(2 * j + 2), origin: rect.minY), height)
                guard y0 < y1 else { continue }
                for i in 0..<n.w {
                    let k = PlazaCampfireLight.blockMix(i: i, j: j, radii: light.radii)
                    guard k > 0 else { continue }
                    let x0 = max(px(left + CGFloat(2 * i), origin: rect.minX), 0), x1 = min(px(left + CGFloat(2 * i + 2), origin: rect.minX), width)
                    guard x0 < x1 else { continue }
                    let m = PlazaCampfireLight.multiplier(tint: light.tint, mix: k * light.level, color: light.color)
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            let o = y * stride + x * 4
                            bytes[o] = UInt8(min(255, (Double(bytes[o]) * m.r).rounded()))
                            bytes[o + 1] = UInt8(min(255, (Double(bytes[o + 1]) * m.g).rounded()))
                            bytes[o + 2] = UInt8(min(255, (Double(bytes[o + 2]) * m.b).rounded()))
                        }
                    }
                }
            }
        }

        for p in input.fireworks {
            draw(p.image, x: px(p.origin.x, origin: rect.minX), top: px(p.origin.y, origin: rect.minY),
                 w: Int((p.size.width * ppw).rounded()), h: Int((p.size.height * ppw).rounded()))
        }

        for a in ordered {
            let centerX = px(a.foot.x, origin: rect.minX)
            var top = px(a.foot.y - a.bob - a.lift, origin: rect.minY) - Int((CGFloat(a.image.height) * a.scale * ppw).rounded())
            if a.sink > 0 { top += Int((a.sink * ppw).rounded()) }   // 이름표는 잘린 윗부분 위에 놓는다
            if let base = a.plateBaseY { top = px(base, origin: rect.minY) }
            if let plate = a.plate {
                top -= plateGap + plate.height
                draw(plate, x: centerX - plate.width / 2, top: top, w: plate.width, h: plate.height)
            }
            if let bubble = a.bubble {
                // 화면처럼 사진 안쪽으로 민다. 이름표가 사진 밖이면 누구 말인지 알 수 없으므로 같이 밖에 둔다.
                let isOnPhoto = (0..<width).contains(centerX) && (0..<height).contains(top)
                top -= bubble.height
                var x = centerX - bubble.width / 2
                if isOnPhoto {
                    x = min(max(x, 0), width - bubble.width)
                    top = max(top, 0)
                }
                draw(bubble, x: x, top: top, w: bubble.width, h: bubble.height)
            }
        }
        return context.makeImage()
    }

    /// 그림에 물빛을 `submergedBlend`만큼 섞은 사본(투명한 곳은 그대로).
    private static func submerged(_ image: CGImage) -> CGImage? {
        guard let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        c.draw(image, in: rect)
        c.setBlendMode(.sourceAtop)
        let w = PlazaPondArt.waterColor
        c.setFillColor(CGColor(srgbRed: w.redComponent, green: w.greenComponent, blue: w.blueComponent, alpha: PlazaPondArt.submergedBlend))
        c.fill(rect)
        return c.makeImage()
    }

    static func pngData(for input: PlazaPhotoInput) -> Data? {
        render(input).flatMap(png)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
