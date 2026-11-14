import AppKit
import ImageIO
import SpriteKit
@testable import PokeTokenBar

// The scenes of the offscreen render harness (windows-port Track A, Task 1). Mac only (SpriteKit).
// Every scene is built through `PlazaScene`'s own public API and driven by a pure function of the frame number:
// `now` is a function of the frame, seeds are fixed (dance style, firework style, Ditto), time advances 1/60 s a frame.

struct PlazaRenderScene {
    let name: String
    let viewport: CGSize
    let backing: CGFloat
    let captures: [Int]
    let build: @MainActor () -> PlazaRenderSetup
}

struct PlazaRenderSetup {
    let scene: PlazaScene
    let step: @MainActor (_ frame: Int) -> Void
    let photo: Bool
}

enum PlazaRenderLook: Hashable {
    case me, ash, brock, misty, dawn, ditto, egg
    /// Frames of three sizes: front steps 28x32 and 26x30, back 30x34.
    case mixed
    /// A real cached sprite by species id (`real-sprites` only).
    case real(Int)
}

/// The scene's wall clock: a pure function of the frame (`base + frame / 60`), set by `step`.
@MainActor final class PlazaRenderClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func date(at frame: Int, base: Date) { date = base.addingTimeInterval(Double(frame) / 60) }
}

@MainActor
enum PlazaRenderScenes {
    static let map = PlazaMapData.map
    static let viewport = CGSize(width: 640, height: 480)

    // MARK: Synthetic characters

    /// Raw premultiplied RGBA bytes -> CGImage through a `CGDataProvider`, the construction `PlazaImage(bitmap:)` will use.
    static func image(_ rgba: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func body(_ look: PlazaRenderLook, front: Bool, step: Int) -> CGImage {
        let (w, h) = look == .egg ? (20, 26) : look == .mixed ? (front ? (step == 0 ? (28, 32) : (26, 30)) : (30, 34)) : (28, 32)
        let colour: (UInt8, UInt8, UInt8) = switch look {
        case .me: (230, 80, 60)
        case .ash: (60, 120, 230)
        case .brock: (200, 160, 60)
        case .misty: (70, 200, 120)
        case .dawn: (200, 90, 200)
        case .ditto: (190, 150, 220)
        case .egg: (245, 240, 220)
        case .mixed: (240, 200, 70)
        case .real: (128, 128, 128)
        }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 4
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
        }
        let cx = Double(w) / 2 - 0.5, cy = Double(h) / 2 + 1
        let rx = Double(w) / 2 - 1, ry = Double(h) / 2 - 2
        for y in 0..<h {
            for x in 0..<w {
                let dx = (Double(x) - cx) / rx, dy = (Double(y) - cy) / ry
                if dx * dx + dy * dy <= 1 { put(x, y, colour) }
            }
        }
        let dark: (UInt8, UInt8, UInt8) = (30, 30, 40)
        if look == .egg {
            for (x, y) in [(6, 10), (12, 14), (8, 18), (13, 8)] { put(x, y, (200, 120, 90)) }
        } else if front {
            put(9, 11, dark); put(18, 11, dark); put(13, 17, dark); put(14, 17, dark)
        } else {
            for x in 8..<20 { put(x, 9, dark) }   // a stripe instead of a face
        }
        if look != .egg { put(step == 0 ? 7 : 20, h - 3, dark); put(step == 0 ? 7 : 20, h - 2, dark) }   // a foot that moves
        return image(px, width: w, height: h)
    }

    static func frames(_ look: PlazaRenderLook) -> PlazaCharacterFrames {
        if case .real(let id) = look, let real = realFrames(id) { return real }
        let front = (0..<2).map { PlazaFrame(image: PlazaImage(cgImage: body(look, front: true, step: $0)), delay: 0.2) }
        let back = (0..<2).map { PlazaFrame(image: PlazaImage(cgImage: body(look, front: false, step: $0)), delay: 0.2) }
        var f = PlazaCharacterFrames(front: front, back: back)
        f.isEgg = look == .egg
        return f
    }

    // MARK: Real sprites

    static var spritesDir: URL? { PlazaRenderEnv.value("PTB_PLAZA_RENDER_SPRITES").map { URL(fileURLWithPath: $0) } }
    static let realSpecies = [25, 6, 150, 94, 133]

    private static func gif(_ url: URL) -> [PlazaFrame]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var out: [PlazaFrame] = []
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            out.append(PlazaFrame(image: PlazaImage(cgImage: image), delay: max(delay, 0.02)))
        }
        return out.isEmpty ? nil : out
    }

    static func realFrames(_ id: Int) -> PlazaCharacterFrames? {
        guard let dir = spritesDir, let front = gif(dir.appendingPathComponent("\(id)-a.gif")) else { return nil }
        let back = gif(dir.appendingPathComponent("\(id)-ba.gif"))
        var f = PlazaCharacterFrames(front: front, back: back ?? front)
        f.backIsFront = back == nil
        return f
    }

    // MARK: Season looks (the controller's `seasonLook`, minus its cache keying)

    private static var looks: [PlazaSeason: PlazaSnowLook?] = [:]
    static func seasonLook(_ season: PlazaSeason) -> PlazaSnowLook? {
        if let built = looks[season] { return built }
        var look: PlazaSnowLook?
        if season != .summer, let sheet = PlazaResources.tileSheet() {
            let art = PlazaResources.tallGrassSheet().map { PlazaSeasonSheet.tallGrass(PlazaImage(cgImage: $0), season: season) }.flatMap(PlazaTallGrassArt.init(sheet:))
            look = PlazaSnowLook(mapImage: PlazaTileArt.mapImage(map, sheet: PlazaSeasonSheet.tiles(PlazaImage(cgImage: sheet), season: season), tallGrass: art), tallGrass: art)
        }
        looks[season] = .some(look)
        return look
    }

    private static var summerMap: PlazaImage?
    private static var tallGrass: PlazaTallGrassArt??
    private static var iceArt: PlazaIceArt?

    // MARK: Stage

    struct Options {
        var me = TilePoint(x: 19, y: 10)
        var zoom = 2
        var backing: CGFloat = 2
        var season = PlazaSeasonChoice.summer
        var hour = 12
        var minute = 0
        var meLook = PlazaRenderLook.me
        var nickname = "Me"
        var date: Date?
    }

    /// The scene plus the frame-pure clock. `members` is the current list handed to `applyMembers`.
    @MainActor final class Stage {
        let scene: PlazaScene
        let base: Date
        let clock: PlazaRenderClock
        var members: [PlazaSceneMember] = []
        var looks: [String: PlazaRenderLook] = [:]
        var applied = Set<String>()

        init(scene: PlazaScene, base: Date, clock: PlazaRenderClock) { self.scene = scene; self.base = base; self.clock = clock }

        func put(_ list: [PlazaSceneMember], looks newLooks: [String: PlazaRenderLook] = [:]) {
            members = list
            for (k, v) in newLooks { looks[k] = v }
            scene.applyMembers(list)
            for m in list where !applied.contains(m.memberID) {
                applied.insert(m.memberID)
                scene.setMemberFrames(m.memberID, PlazaRenderScenes.frames(looks[m.memberID] ?? .ash))
            }
        }

        /// Replace one member's fields, keep the others.
        func move(_ id: String, to tile: TilePoint? = nil, facing: PlazaDirection? = nil, walking: Bool? = nil, diving: Bool? = nil) {
            var list = members
            guard let i = list.firstIndex(where: { $0.memberID == id }) else { return }
            let m = list[i]
            var n = PlazaSceneMember(memberID: m.memberID, nickname: m.nickname, isAway: m.isAway, tile: tile ?? m.tile,
                                     facing: facing ?? m.facing, isWalking: walking ?? m.isWalking)
            n.isIdle = m.isIdle; n.nameColor = m.nameColor; n.isRunning = m.isRunning
            n.isDiving = diving ?? m.isDiving; n.evolutionStage = m.evolutionStage; n.nature = m.nature
            list[i] = n
            put(list)
        }
    }

    static func member(_ id: String, _ name: String? = nil, _ x: Int, _ y: Int, facing: PlazaDirection = .down, walking: Bool = false,
                       idle: Bool = false, color: UInt32? = nil, nature: PokemonNature? = nil, diving: Bool = false) -> PlazaSceneMember {
        var m = PlazaSceneMember(memberID: id, nickname: name ?? id, isAway: false, tile: TilePoint(x: x, y: y), facing: facing, isWalking: walking)
        m.isIdle = idle; m.nameColor = color; m.nature = nature; m.isDiving = diving
        return m
    }

    /// Me + four teammates near `me`: two idle, two that walk.
    static func crowd(_ me: TilePoint) -> [PlazaSceneMember] {
        [member("ash", "Ash", me.x + 2, me.y, facing: .left),
         member("brock", "Brock", me.x - 2, me.y + 1, facing: .down, walking: true),
         member("misty", "Misty", me.x + 1, me.y - 2, facing: .up),
         member("dawn", "Dawn", me.x + 3, me.y + 2, facing: .right, walking: true)]
    }
    static let crowdLooks: [String: PlazaRenderLook] = ["ash": .ash, "brock": .brock, "misty": .misty, "dawn": .dawn]

    static func stage(_ o: Options = Options()) -> Stage {
        if summerMap == nil {
            let grass = PlazaTallGrassArt.load()
            tallGrass = .some(grass)
            iceArt = PlazaIceArt.load()
            let sheet = PlazaResources.tileSheet().map(PlazaImage.init(cgImage:))
            summerMap = sheet.map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: grass) } ?? PlazaTileArt.plainGrassImage(map)
        }
        let scene = PlazaScene(map: map, mapImage: summerMap!, start: o.me, zoom: o.zoom, nickname: o.nickname,
                               tallGrass: tallGrass ?? nil, pondVisuals: true, iceArt: iceArt)
        scene.backingOverride = o.backing
        scene.size = viewport
        let base = o.date ?? Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: o.hour, minute: o.minute))!
        let clock = PlazaRenderClock(base)
        scene.now = { clock.date }
        scene.seasonLook = { seasonLook($0) }
        scene.pickDanceStyle = { _ in .twirl }
        scene.currentModifiers = { [] }
        scene.seasonChoice = o.season
        scene.refreshSnowDay()
        scene.setCharacter(frames(o.meLook))
        return Stage(scene: scene, base: base, clock: clock)
    }

    private static func setup(_ s: Stage, photo: Bool = false, _ step: @escaping @MainActor (Int) -> Void = { _ in }) -> PlazaRenderSetup {
        PlazaRenderSetup(scene: s.scene, step: { frame in
            s.clock.date(at: frame, base: s.base)
            step(frame)
        }, photo: photo)
    }

    private static func scene(_ name: String, backing: CGFloat = 2, captures: [Int], build: @escaping @MainActor () -> PlazaRenderSetup) -> PlazaRenderScene {
        PlazaRenderScene(name: name, viewport: viewport, backing: backing, captures: captures, build: build)
    }

    static func press(_ s: Stage, _ code: UInt16) { s.scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false) }
    static func release(_ s: Stage, _ code: UInt16) { s.scene.handleKeyUp(keyCode: code) }
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    // MARK: Scene builders

    private static func base(_ name: String, backing: CGFloat, zoom: Int, captures: [Int] = [10, 40, 90], photo: Bool = false) -> PlazaRenderScene {
        scene(name, backing: backing, captures: captures) {
            var o = Options(); o.zoom = zoom; o.backing = backing
            let s = stage(o)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo) { f in
                switch f {
                case 1: s.move("brock", to: TilePoint(x: 17, y: 13), walking: true); s.move("dawn", to: TilePoint(x: 22, y: 14), walking: true)
                case 30: press(s, right)
                case 60: release(s, right)
                default: break
                }
            }
        }
    }

    private static func daylight(_ name: String, hour: Int, minute: Int = 0, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10]) {
            var o = Options(); o.hour = hour; o.minute = minute
            let s = stage(o)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo)
        }
    }

    private static func season(_ name: String, _ choice: PlazaSeasonChoice, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10, 60]) {
            var o = Options(); o.season = choice
            let s = stage(o)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo)
        }
    }

    private static func campfire(_ name: String, hour: Int, lit: Bool, smoke: Bool = false, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10, 37, 64]) {
            var o = Options(); o.hour = hour
            o.me = PlazaCampfire.seats[0].tile
            let s = stage(o)
            s.scene.sit(at: PlazaCampfire.seats[0])
            let seats = PlazaCampfire.seats
            s.put([member("ash", "Ash", seats[1].tile.x, seats[1].tile.y, facing: seats[1].facing),
                   member("brock", "Brock", seats[2].tile.x, seats[2].tile.y, facing: seats[2].facing),
                   member("misty", "Misty", seats[4].tile.x, seats[4].tile.y, facing: seats[4].facing)], looks: crowdLooks)
            s.scene.campfireLit = lit || smoke
            if lit { s.scene.setCampfireTimer("24:59") }
            return setup(s, photo: photo) { f in
                if smoke, f == 1 { s.scene.campfireLit = false; s.scene.setCampfireTimer(nil) }
            }
        }
    }

    private static func pond(_ name: String, egg: Bool, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [5, 20, 45]) {
            var o = Options(); o.me = TilePoint(x: egg ? 12 : 9, y: egg ? 12 : 14)
            if egg { o.meLook = .egg }
            let s = stage(o)
            if egg {
                // one egg in the water (sunk), one on land with its nest rim, me an egg on the shore
                s.put([member("e1", "Egg1", 9, 14), member("e2", "Egg2", 10, 12), member("ash", "Ash", 13, 12, facing: .left)],
                      looks: ["e1": .egg, "e2": .egg, "ash": .ash])
                return setup(s, photo: photo)
            }
            s.put([member("ash", "Ash", 7, 14, facing: .right), member("brock", "Brock", 11, 14, diving: true),
                   member("misty", "Misty", 10, 12, facing: .down), member("dawn", "Dawn", 8, 13, facing: .down, walking: true)],
                  looks: crowdLooks)
            return setup(s, photo: photo) { f in
                switch f {
                case 1: s.move("dawn", to: TilePoint(x: 8, y: 14), walking: true)
                case 3: s.scene.playJump(memberID: nil)
                case 12: s.move("brock", diving: false)   // surfaces: a big splash
                case 14: s.scene.setDiving(true)
                case 30: s.move("ash", to: TilePoint(x: 6, y: 14), walking: true)
                default: break
                }
            }
        }
    }

    private static func ice(_ name: String, _ script: @escaping @MainActor (Stage, Int) -> Void) -> PlazaRenderScene {
        scene(name, captures: [5, 20, 40]) {
            var o = Options(); o.season = .winter; o.me = TilePoint(x: 10, y: 12)
            let s = stage(o)
            s.put([member("ash", "Ash", 8, 14), member("brock", "Brock", 12, 12, facing: .left)], looks: crowdLooks)
            return setup(s) { f in script(s, f) }
        }
    }

    private static func iceBreak(_ s: Stage, at offset: TimeInterval = 0) -> PlazaIceBreak {
        PlazaIceBreak(at: s.base.timeIntervalSince1970 + offset, pond: PlazaIce.ponds(in: map)[0].anchor)
    }

    /// A chat/plate scene: seven teammates in a row, rendered at both backing scales.
    private static func row(_ s: Stage, _ ms: [PlazaSceneMember]) {
        s.put(ms, looks: ["a": .ash, "b": .brock, "c": .misty, "d": .dawn, "e": .ash, "f": .brock, "g": .misty])
    }

    private static func chatScene(_ name: String, backing: CGFloat) -> PlazaRenderScene {
        scene(name, backing: backing, captures: [10]) {
            var o = Options(); o.backing = backing
            let s = stage(o)
            row(s, [member("a", "Ash", 16, 9), member("b", "Brock", 19, 8), member("c", "Misty", 22, 9),
                    member("d", "Dawn", 14, 11), member("e", "Eve", 18, 12), member("f", "Fay", 23, 12)])
            return setup(s) { f in
                guard f == 1 else { return }
                s.scene.showChat(memberID: "a", text: "Hello there, nice to meet you!")
                s.scene.showChat(memberID: "b", text: "안녕하세요 오늘도 열심히 해봐요")
                s.scene.showChat(memberID: "c", text: "🔥 deploy done 🎉🥳")
                s.scene.showChat(memberID: "d", text: String(repeating: "wrap me ", count: 8).trimmingCharacters(in: .whitespaces).prefix(60).description)
                s.scene.showChat(memberID: "e", text: "ok")
                s.scene.showChat(memberID: nil, text: "edge push 좌우 끝")
                s.scene.showChat(memberID: "f", text: "Far right edge bubble that must be pushed back inside the view")
            }
        }
    }

    private static func plateScene(_ name: String, backing: CGFloat) -> PlazaRenderScene {
        scene(name, backing: backing, captures: [10]) {
            var o = Options(); o.backing = backing; o.nickname = "Me"
            let s = stage(o)
            row(s, [member("a", "Titled", 16, 9, nature: .adamant), member("b", "Sleepy", 19, 8, idle: true),
                    member("c", "A very long nickname that must be truncated somewhere", 22, 9),
                    member("d", "한글이름", 14, 11, color: 0xFF8800), member("e", "", 18, 12), member("f", "🔥Fire", 23, 12, color: 0x22CC88)])
            return setup(s)
        }
    }

    private static func ditto(_ name: String, decoy: Bool, poof: Bool) -> PlazaRenderScene {
        scene(name, captures: [5, 15, 25]) {
            let s = stage()
            s.put(crowd(Options().me), looks: crowdLooks)
            let shown = PlazaDittoShown(tile: TilePoint(x: 19, y: 12), facing: .down, isWalking: false, isRunning: false,
                                        name: decoy ? "Ash" : "Ditto", nameColor: PlazaNameColor.palette[1], title: nil, isDecoy: decoy)
            s.scene.applyDitto(shown)
            s.scene.setMemberFrames(PlazaDitto.sceneKey, frames(decoy ? .ash : .ditto))
            return setup(s) { f in
                switch f {
                case 1 where poof: s.scene.playDittoPoof()
                case 3 where poof:
                    var moved = shown; moved.tile = TilePoint(x: 20, y: 12); moved.isWalking = true
                    s.scene.applyDitto(moved)
                case 8 where !poof:
                    var moved = shown; moved.tile = TilePoint(x: 18, y: 12); moved.isWalking = true
                    s.scene.applyDitto(moved)
                default: break
                }
            }
        }
    }

    private static func fireworks(_ name: String, hour: Int, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10, 30, 60]) {
            var o = Options(); o.hour = hour
            let s = stage(o)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo) { f in
                switch f {
                case 1: _ = s.scene.playFirework(memberID: nil, style: "ring")
                case 8: _ = s.scene.playFirework(memberID: "ash", style: "willow")
                case 20: _ = s.scene.playFirework(memberID: "misty", style: "heartShape")
                default: break
                }
            }
        }
    }

    private static func throwing(_ name: String, choice: PlazaSeasonChoice) -> PlazaRenderScene {
        scene(name, captures: [5, 12, 20]) {
            var o = Options(); o.season = choice
            let s = stage(o)
            s.put([member("ash", "Ash", 15, 10, facing: .right), member("brock", "Brock", 24, 10, facing: .left),
                   member("misty", "Misty", 19, 7, facing: .down)], looks: crowdLooks)
            return setup(s) { f in
                switch f {
                case 1:
                    s.scene.playSnowball(by: "ash", shot: PlazaSnowballShot(from: TilePoint(x: 15, y: 10), direction: .right,
                                                                              end: .actor(id: nil, tile: TilePoint(x: 19, y: 10))), onLand: {})
                case 3:
                    s.scene.playSnowball(by: "brock", shot: PlazaSnowballShot(from: TilePoint(x: 24, y: 10), direction: .left,
                                                                                end: .ground(TilePoint(x: 21, y: 10))), onLand: {})
                case 6:
                    s.scene.playSnowball(by: nil, shot: PlazaSnowballShot(from: TilePoint(x: 19, y: 10), direction: .up,
                                                                            end: .actor(id: "misty", tile: TilePoint(x: 19, y: 7))), onLand: {})
                default: break
                }
            }
        }
    }

    private static func effect(_ name: String, _ fire: @escaping @MainActor (Stage) -> Void) -> PlazaRenderScene {
        scene(name, captures: [3, 10, 22]) {
            let s = stage()
            s.put(crowd(Options().me), looks: crowdLooks)
            return setup(s) { f in if f == 1 { fire(s) } }
        }
    }

    /// The first item the real map shows, with `me` two tiles west of it.
    private static func itemScene() -> PlazaRenderScene {
        scene("items", captures: [10, 40]) {
            let open = PlazaItems.openTiles(in: map)
            var slot = PlazaItems.slot(at: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!)
            var spawn = PlazaItems.spawn(slot: slot, candidates: PlazaItems.spawnCandidates)
            while spawn == nil || !PlazaItems.isShown(spawn!, openTiles: open) || !open.contains(TilePoint(x: spawn!.tile.x - 2, y: spawn!.tile.y)) {
                slot += 1
                spawn = PlazaItems.spawn(slot: slot, candidates: PlazaItems.spawnCandidates)
            }
            var o = Options()
            o.date = spawn!.appearsAt.addingTimeInterval(5)
            o.me = TilePoint(x: spawn!.tile.x - 2, y: spawn!.tile.y)
            let s = stage(o)
            s.put([member("ash", "Ash", spawn!.tile.x, min(spawn!.tile.y + 2, 28))], looks: crowdLooks)
            return setup(s)
        }
    }

    // MARK: All scenes

    static let all: [PlazaRenderScene] = makeAll()

    private static func makeAll() -> [PlazaRenderScene] {
        var out: [PlazaRenderScene] = [
            base("base-noon", backing: 1, zoom: 2, photo: true), base("base-noon-2x", backing: 2, zoom: 2),
            base("zoom-1", backing: 2, zoom: 1), base("zoom-4", backing: 2, zoom: 4),
            daylight("dusk", hour: 18, minute: 40), daylight("night", hour: 23, photo: true),
            season("spring", .spring), season("autumn", .autumn), season("winter-snow", .winter, photo: true),
            scene("winter-footprints", captures: [30, 120, 400]) {
                var o = Options(); o.season = .winter; o.me = TilePoint(x: 8, y: 10)
                let s = stage(o)
                s.put([member("ash", "Ash", 12, 9, facing: .left)], looks: crowdLooks)
                return setup(s) { f in
                    switch f {
                    case 1: press(s, right)
                    case 140: release(s, right); press(s, down)
                    case 220: release(s, down); press(s, left)
                    case 300: release(s, left)
                    default: break
                    }
                }
            },
            campfire("campfire-ready", hour: 12, lit: false), campfire("campfire-lit-night", hour: 23, lit: true, photo: true),
            campfire("campfire-smoke", hour: 12, lit: false, smoke: true),
            pond("pond-swim", egg: false, photo: true), pond("pond-egg", egg: true),
            ice("ice-frozen") { _, _ in },
            ice("ice-breaking") { s, f in if f == 1 { s.scene.setIceBreak(iceBreak(s), hit: TilePoint(x: 9, y: 14)) } },
            ice("ice-refreeze") { s, f in
                if f == 1 { s.scene.setIceBreak(iceBreak(s), hit: TilePoint(x: 9, y: 14)) }
                if f >= 4 { s.clock.date = s.base.addingTimeInterval(PlazaIce.refreezeDelay + Double(f - 4) / 60) }
            },
            scene("tall-grass", captures: [5, 20, 50]) {
                var o = Options(); o.me = TilePoint(x: 12, y: 7)
                let s = stage(o)
                s.put([member("ash", "Ash", 8, 6), member("brock", "Brock", 9, 7, facing: .right, walking: true)], looks: crowdLooks)
                return setup(s, photo: true) { f in
                    switch f {
                    case 2: press(s, left)
                    case 30: release(s, left)
                    case 3: s.move("brock", to: TilePoint(x: 10, y: 7), walking: true)
                    default: break
                    }
                }
            },
            scene("dance", captures: [7, 23, 41]) {
                let s = stage()
                s.put(crowd(Options().me), looks: crowdLooks)
                return setup(s, photo: true) { f in
                    if f == 1 {
                        press(s, 2)   // D: my dance, the injected style is twirl
                        _ = s.scene.playDance(memberID: "ash", style: "bigHop")
                        _ = s.scene.playDance(memberID: "misty", style: "spin")
                    }
                }
            },
            scene("pray-wobble", captures: [7, 23, 41]) {
                var o = Options(); o.meLook = .egg
                let s = stage(o)
                s.put([member("e1", "Egg1", 21, 10), member("ash", "Ash", 17, 10)], looks: ["e1": .egg, "ash": .ash])
                return setup(s) { f in if f == 1 { s.scene.playPray(memberID: nil); s.scene.playPray(memberID: "e1") } }
            },
            scene("emotes", captures: [10]) {
                let s = stage()
                row(s, [member("a", "Ash", 16, 9), member("b", "Brock", 18, 8), member("c", "Misty", 21, 8),
                        member("d", "Dawn", 22, 10), member("e", "Eve", 16, 12), member("f", "Fay", 22, 12)])
                return setup(s) { f in
                    guard f == 1 else { return }
                    let kinds = TeamEmoteKind.allCases.filter { $0 != .decoyFound && $0 != .decoyJump }
                    for (i, id) in ([String?.none] + ["a", "b", "c", "d", "e", "f"].map { Optional($0) }).enumerated() where i < kinds.count {
                        s.scene.showEmote(memberID: id, kind: kinds[i])
                    }
                }
            },
            chatScene("chat-bubbles", backing: 2), chatScene("chat-bubbles-1x", backing: 1),
            plateScene("name-plates", backing: 2), plateScene("name-plates-1x", backing: 1),
            ditto("ditto", decoy: false, poof: false), ditto("ditto-decoy", decoy: true, poof: false), ditto("ditto-poof", decoy: false, poof: true),
            fireworks("fireworks-night", hour: 23, photo: true), fireworks("fireworks-day", hour: 12),
            throwing("snowballs", choice: .winter), throwing("water-balloon", choice: .summer),
            effect("jump-dust") { s in s.scene.playJump(memberID: nil); s.scene.playJump(memberID: "ash") },
            effect("tackle-impact") { s in s.scene.playTackle(by: "ash", on: nil, direction: .right) },
            effect("shutter") { s in s.scene.playShutterFlash() },
            effect("sparkle") { s in s.scene.playSparkle(memberID: nil); s.scene.playSparkle(memberID: "misty") },
            itemScene(),
            scene("board-marker", captures: [10, 40]) {
                var o = Options(); o.zoom = 1; o.me = TilePoint(x: 24, y: 8)
                let s = stage(o)
                s.put([member("ash", "Ash", 21, 9)], looks: crowdLooks)
                s.scene.setBoardMarker(visible: true)
                return setup(s)
            },
            scene("wet", captures: [10, 40]) {
                let s = stage()
                s.put(crowd(Options().me), looks: crowdLooks)
                s.scene.myActor.showWet()
                s.scene.memberActor("ash")?.showWet()
                return setup(s)
            },
            scene("background-hidden", captures: [10]) {
                let s = stage()
                s.put(crowd(Options().me), looks: crowdLooks)
                s.scene.setBackgroundHidden(true)
                return setup(s)
            },
            scene("photo-mode", captures: [10, 30]) {
                let s = stage()
                s.put(crowd(Options().me), looks: crowdLooks)
                return setup(s) { f in
                    switch f {
                    case 1: s.scene.enterPhotoMode()
                    case 8: press(s, right)
                    case 20: release(s, right); press(s, up)
                    case 28: release(s, up)
                    default: break
                    }
                }
            },
            // Members leave (the actor's detach): a swimmer with a chat bubble (ghost crop showing) and a wet walker go,
            // the Ditto changes form and then goes, and a late member joins after them.
            scene("member-leave", captures: [8, 16, 24, 32]) {
                var o = Options(); o.me = TilePoint(x: 12, y: 12)
                let s = stage(o)
                let stay = member("ash", "Ash", 13, 12, facing: .left)
                s.put([stay, member("swimmer", "Swimmer", 9, 14), member("wet", "Wet", 10, 12, facing: .right, walking: true)],
                      looks: ["ash": .ash, "swimmer": .misty, "wet": .brock])
                s.scene.memberActor("wet")?.showWet()
                s.scene.applyDitto(PlazaDittoShown(tile: TilePoint(x: 11, y: 11), facing: .down, isWalking: false, isRunning: false,
                                                   name: "Ditto", nameColor: PlazaNameColor.palette[1], title: nil, isDecoy: false))
                s.scene.setMemberFrames(PlazaDitto.sceneKey, frames(.ditto))
                return setup(s) { f in
                    switch f {
                    case 1: s.scene.showChat(memberID: "swimmer", text: "bye for now")
                    case 10: s.put([stay])
                    case 12: s.scene.setMemberFrames(PlazaDitto.sceneKey, frames(.dawn))
                    case 18: s.scene.applyDitto(nil)
                    case 20: s.put([stay, member("late", "Late", 14, 11)], looks: ["late": .dawn])
                    default: break
                    }
                }
            },
            // A swimmer whose pond rect changes (the ghost crop's mask moves: pond A -> C -> A), one facing back in the
            // water, the Ditto changing form while it swims, and a swimmer whose frames arrive late (placed before).
            scene("pond-hop", captures: [4, 10, 16, 28]) {
                var o = Options(); o.zoom = 1; o.me = TilePoint(x: 14, y: 19)
                let s = stage(o)
                s.applied.insert("late")   // its frames arrive at frame 6
                s.put([member("hopper", "Hopper", 7, 14), member("back", "Back", 10, 14, facing: .up),
                       member("late", "Late", 20, 24)], looks: ["hopper": .misty, "back": .ash])
                s.scene.applyDitto(PlazaDittoShown(tile: TilePoint(x: 13, y: 14), facing: .left, isWalking: false, isRunning: false,
                                                   name: "Ditto", nameColor: PlazaNameColor.palette[1], title: nil, isDecoy: false))
                s.scene.setMemberFrames(PlazaDitto.sceneKey, frames(.ditto))
                return setup(s) { f in
                    switch f {
                    case 6: s.scene.setMemberFrames("late", frames(.brock))
                    case 8: s.scene.setMemberFrames(PlazaDitto.sceneKey, frames(.dawn))
                    case 12: s.move("hopper", to: TilePoint(x: 22, y: 25))
                    case 24: s.move("hopper", to: TilePoint(x: 6, y: 15))
                    default: break
                    }
                }
            },
            // Lunges to the right, up and down (the effect scenes only lunge left), and frames of three sizes walking.
            scene("lunges", captures: [3, 9, 15, 24]) {
                let s = stage()
                s.put([member("ash", "Ash", 17, 10, facing: .right), member("misty", "Misty", 21, 9),
                       member("dawn", "Dawn", 21, 11, facing: .up), member("mix", "Mix", 16, 12)],
                      looks: ["ash": .ash, "misty": .misty, "dawn": .dawn, "mix": .mixed])
                return setup(s) { f in
                    switch f {
                    case 1: s.scene.playTackle(by: "ash", on: nil, direction: .right); s.move("mix", to: TilePoint(x: 17, y: 12), walking: true)
                    case 7: s.scene.playTackle(by: "dawn", on: "misty", direction: .up)
                    case 9: s.move("mix", to: TilePoint(x: 17, y: 11), facing: .up, walking: true)
                    case 13: s.scene.playTackle(by: "misty", on: "dawn", direction: .down)
                    default: break
                    }
                }
            },
        ]
        if spritesDir != nil, realFrames(realSpecies[0]) != nil {
            out.append(scene("real-sprites", captures: [10, 30]) {
                var o = Options(); o.me = TilePoint(x: 10, y: 12); o.meLook = .real(realSpecies[0])
                let s = stage(o)
                s.put([member("a", "A", 12, 12), member("b", "B", 8, 14), member("c", "C", 13, 10), member("d", "D", 7, 12)],
                      looks: ["a": .real(realSpecies[1]), "b": .real(realSpecies[2]), "c": .real(realSpecies[3]), "d": .real(realSpecies[4])])
                return setup(s, photo: true) { f in
                    if f == 1 { press(s, 2); _ = s.scene.playDance(memberID: "a", style: "sway") }
                    if f == 2 { s.move("b", to: TilePoint(x: 9, y: 14), walking: true) }
                }
            })
        }
        if let only = PlazaRenderEnv.only { out = out.filter { only.contains($0.name) } }
        return out
    }
}
