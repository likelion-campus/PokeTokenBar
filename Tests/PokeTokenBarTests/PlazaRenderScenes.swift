import Foundation
@testable import PokeTokenBar

// The scenes of the render harness (windows-port Track A Task 1; shared since stage 6 Task 15). Shared code: the Mac's
// SpriteKit harness and the Windows Direct2D harness build the SAME scenes from these builders, with the same fixture
// bytes, clock and seeds, each on its own `PlazaStage` (`build(stage)`).
// Every scene is built through `PlazaScene`'s own public API and driven by a pure function of the frame number:
// `now` is a function of the frame, seeds are fixed (dance style, firework style, Ditto), time advances 1/60 s a frame.

struct PlazaRenderScene {
    let name: String
    let viewport: CGSize
    let backing: CGFloat
    let captures: [Int]
    let build: @MainActor (_ stage: any PlazaStage) -> PlazaRenderSetup
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
    /// A real cached sprite by species id (`real-sprites` only, Mac harness).
    case real(Int)
}

/// The scene's wall clock: a pure function of the frame (`base + frame / 60`), set by `step`.
@MainActor final class PlazaRenderClock {
    var date: Date
    init(_ date: Date) { self.date = date }
    func date(at frame: Int, base: Date) { date = base.addingTimeInterval(Double(frame) / 60) }
}

/// Environment switches of the harnesses (every harness test skips without its variable).
enum PlazaRenderEnv {
    static func value(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty ?? true) ? nil : v
    }
    static var only: Set<String>? {
        value("PTB_PLAZA_RENDER_ONLY").map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    }
}

/// The fixture clock's time zone, pinned. The scenes read the hour of `now()` through `Calendar.current` (daylight tint,
/// campfire timer) and the item schedule from the instant, so the same wall-clock fixture is a different instant (and a
/// different set of nodes) on a machine in another zone: Task 4 found the Mac in KST and the UTC runner disagreeing on an
/// item node. The zone is a FIXED offset (+09:00, no DST, no zone database needed: the maintainer's Mac is in KST, so the
/// renders did not move), applied as `NSTimeZone.default` for the length of a run and restored after.
@MainActor
enum PlazaFixtureTime {
    static let offsetSeconds = 9 * 3600
    static var zone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds)! }
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// Pins the process zone; `restore()` puts the previous one back. `Calendar.current` must follow (checked: a Foundation
    /// that ignored the default would silently keep the host's zone).
    struct Pin {
        fileprivate let previous: TimeZone
        func restore() { NSTimeZone.default = previous }
    }

    static func pin() -> Pin {
        let pin = Pin(previous: NSTimeZone.default)
        NSTimeZone.default = zone
        precondition(Calendar.current.timeZone.secondsFromGMT() == offsetSeconds, "Calendar.current ignores the pinned time zone")
        return pin
    }

    static func date(year: Int = 2026, month: Int = 6, day: Int = 15, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

@MainActor
enum PlazaRenderScenes {
    static let map = PlazaMapData.map
    static let viewport = CGSize(width: 640, height: 480)

    // MARK: Synthetic characters

    /// The harness's own fixtures are built from raw bytes through `PlazaImage(bitmap:)` (no AppKit, the same pixels on
    /// both OSes). The Mac keeps `PlazaRenderScenes.image` (`+Mac`): the CGImage of the same bytes, for its oracles.
    static func bitmapBytes(_ look: PlazaRenderLook, front: Bool, step: Int) -> (bytes: [UInt8], width: Int, height: Int) {
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
        return (px, w, h)
    }

    private static func body(_ look: PlazaRenderLook, front: Bool, step: Int) -> PlazaImage {
        let b = bitmapBytes(look, front: front, step: step)
        return PlazaImage(bitmap: PlazaBitmap(width: b.width, height: b.height, bytes: b.bytes))
    }

    /// Mac harness only: a real cached sprite by species id (`PlazaRenderScenes+Mac.swift` installs it).
    static var realFramesProvider: (@MainActor (Int) -> PlazaCharacterFrames?)?

    static func frames(_ look: PlazaRenderLook) -> PlazaCharacterFrames {
        if case .real(let id) = look, let real = realFramesProvider?(id) { return real }
        let front = (0..<2).map { PlazaFrame(image: body(look, front: true, step: $0), delay: 0.2) }
        let back = (0..<2).map { PlazaFrame(image: body(look, front: false, step: $0), delay: 0.2) }
        var f = PlazaCharacterFrames(front: front, back: back)
        f.isEgg = look == .egg
        return f
    }

    // MARK: Season looks (the controller's `seasonLook`, minus its cache keying)

    private static var looks: [PlazaSeason: PlazaSnowLook?] = [:]
    static func seasonLook(_ season: PlazaSeason) -> PlazaSnowLook? {
        if let built = looks[season] { return built }
        var look: PlazaSnowLook?
        if season != .summer, let sheet = PlatformPlaza.tileSheet() {
            look = PlazaSeasonSheet.look(map, sheet: sheet, tallGrassSheet: PlatformPlaza.tallGrassSheet(), season: season)
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

    /// `stage` is the platform's (SpriteKit on the Mac, Direct2D on Windows, headless for dumps); nil takes the platform default.
    static func stage(_ o: Options = Options(), on platformStage: (any PlazaStage)? = nil) -> Stage {
        if summerMap == nil {
            let grass = PlatformPlaza.tallGrassArt()
            tallGrass = .some(grass)
            iceArt = PlatformPlaza.iceArt()
            summerMap = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: grass) } ?? PlazaTileArt.plainGrassImage(map)
        }
        let stage = platformStage ?? PlatformPlaza.makeStage(size: CGSize(width: 960, height: 640))
        let scene = PlazaScene(map: map, mapImage: summerMap!, start: o.me, zoom: o.zoom, nickname: o.nickname,
                               tallGrass: tallGrass ?? nil, pondVisuals: true, iceArt: iceArt, stage: stage)
        scene.backingOverride = o.backing
        scene.size = viewport
        let base = o.date ?? PlazaFixtureTime.date(hour: o.hour, minute: o.minute)
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

    static func setup(_ s: Stage, photo: Bool = false, _ step: @escaping @MainActor (Int) -> Void = { _ in }) -> PlazaRenderSetup {
        PlazaRenderSetup(scene: s.scene, step: { frame in
            s.clock.date(at: frame, base: s.base)
            step(frame)
        }, photo: photo)
    }

    private static func scene(_ name: String, backing: CGFloat = 2, captures: [Int], build: @escaping @MainActor (any PlazaStage) -> PlazaRenderSetup) -> PlazaRenderScene {
        PlazaRenderScene(name: name, viewport: viewport, backing: backing, captures: captures, build: build)
    }

    static func press(_ s: Stage, _ code: UInt16) { s.scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false) }
    static func release(_ s: Stage, _ code: UInt16) { s.scene.handleKeyUp(keyCode: code) }
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    // MARK: Scene builders

    private static func base(_ name: String, backing: CGFloat, zoom: Int, captures: [Int] = [10, 40, 90], photo: Bool = false) -> PlazaRenderScene {
        scene(name, backing: backing, captures: captures) { st in
            var o = Options(); o.zoom = zoom; o.backing = backing
            let s = stage(o, on: st)
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
        scene(name, captures: [10]) { st in
            var o = Options(); o.hour = hour; o.minute = minute
            let s = stage(o, on: st)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo)
        }
    }

    private static func season(_ name: String, _ choice: PlazaSeasonChoice, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10, 60]) { st in
            var o = Options(); o.season = choice
            let s = stage(o, on: st)
            s.put(crowd(o.me), looks: crowdLooks)
            return setup(s, photo: photo)
        }
    }

    /// 왼쪽 위 모서리(나무·풀숲·꽃·왼쪽 연못의 연잎)를 줌 1로 본다. 가운데 시점에는 나무가 안 들어온다.
    private static func edge(_ name: String, _ choice: PlazaSeasonChoice) -> PlazaRenderScene {
        scene(name, captures: [10]) { st in
            var o = Options(); o.season = choice; o.zoom = 1; o.me = TilePoint(x: 4, y: 4)
            return setup(stage(o, on: st))
        }
    }

    private static func campfire(_ name: String, hour: Int, lit: Bool, smoke: Bool = false, photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: [10, 37, 64]) { st in
            var o = Options(); o.hour = hour
            o.me = PlazaCampfire.seats[0].tile
            let s = stage(o, on: st)
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
        scene(name, captures: [5, 20, 45]) { st in
            var o = Options(); o.me = TilePoint(x: egg ? 12 : 9, y: egg ? 12 : 14)
            if egg { o.meLook = .egg }
            let s = stage(o, on: st)
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

    /// 오른쪽 연못(온천): 가운데에서 헤엄치는 나와 물가·물 속 이웃. Task 7 전에는 옛 연못이 보인다.
    private static func hotSpring(_ name: String, _ choice: PlazaSeasonChoice, hour: Int = 12, zoom: Int, captures: [Int], photo: Bool = false) -> PlazaRenderScene {
        scene(name, captures: captures) { st in
            var o = Options(); o.season = choice; o.hour = hour; o.zoom = zoom; o.me = TilePoint(x: 35, y: 17)
            let s = stage(o, on: st)
            s.put([member("ash", "Ash", 33, 16, facing: .right), member("misty", "Misty", 37, 18, facing: .left),
                   member("brock", "Brock", 35, 21, facing: .up)], looks: crowdLooks)
            return setup(s, photo: photo)
        }
    }

    private static func ice(_ name: String, _ script: @escaping @MainActor (Stage, Int) -> Void) -> PlazaRenderScene {
        scene(name, captures: [5, 20, 40]) { st in
            var o = Options(); o.season = .winter; o.me = TilePoint(x: 10, y: 12)
            let s = stage(o, on: st)
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
        scene(name, backing: backing, captures: [10]) { st in
            var o = Options(); o.backing = backing
            let s = stage(o, on: st)
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
        scene(name, backing: backing, captures: [10]) { st in
            var o = Options(); o.backing = backing; o.nickname = "Me"
            let s = stage(o, on: st)
            row(s, [member("a", "Titled", 16, 9, nature: .adamant), member("b", "Sleepy", 19, 8, idle: true),
                    member("c", "A very long nickname that must be truncated somewhere", 22, 9),
                    member("d", "한글이름", 14, 11, color: 0xFF8800), member("e", "", 18, 12), member("f", "🔥Fire", 23, 12, color: 0x22CC88)])
            return setup(s)
        }
    }

    private static func ditto(_ name: String, decoy: Bool, poof: Bool) -> PlazaRenderScene {
        scene(name, captures: [5, 15, 25]) { st in
            let s = stage(on: st)
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
        scene(name, captures: [10, 30, 60]) { st in
            var o = Options(); o.hour = hour
            let s = stage(o, on: st)
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
        scene(name, captures: [5, 12, 20, 26, 32]) { st in
            var o = Options(); o.season = choice
            let s = stage(o, on: st)
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
        scene(name, captures: [3, 10, 22]) { st in
            let s = stage(on: st)
            s.put(crowd(Options().me), looks: crowdLooks)
            return setup(s) { f in if f == 1 { fire(s) } }
        }
    }

    /// The first item the real map shows, with `me` two tiles west of it.
    private static func itemScene() -> PlazaRenderScene {
        scene("items", captures: [10, 40]) { st in
            let open = PlazaItems.openTiles(in: map)
            var slot = PlazaItems.slot(at: PlazaFixtureTime.date(hour: 12))
            var spawn = PlazaItems.spawn(slot: slot, candidates: PlazaItems.spawnCandidates)
            while spawn == nil || !PlazaItems.isShown(spawn!, openTiles: open) || !open.contains(TilePoint(x: spawn!.tile.x - 2, y: spawn!.tile.y)) {
                slot += 1
                spawn = PlazaItems.spawn(slot: slot, candidates: PlazaItems.spawnCandidates)
            }
            var o = Options()
            o.date = spawn!.appearsAt.addingTimeInterval(5)
            o.me = TilePoint(x: spawn!.tile.x - 2, y: spawn!.tile.y)
            let s = stage(o, on: st)
            s.put([member("ash", "Ash", spawn!.tile.x, min(spawn!.tile.y + 2, 28))], looks: crowdLooks)
            return setup(s)
        }
    }

    // MARK: All scenes

    /// The Mac harness's `real-sprites` scene (real cached GIFs, never committed): `PlazaRenderScenes+Mac.swift` installs it.
    static var realSpritesScene: (@MainActor () -> PlazaRenderScene?)?

    static var all: [PlazaRenderScene] { makeAll() }

    /// Scenes only the cross-OS compare renders: `base-noon` at the fractional display scales Windows has and the Mac has not
    /// (not in `all`, so the Mac's own base-vs-head compare is unchanged).
    static var crossExtras: [PlazaRenderScene] {
        let list = [base("base-noon-1.25x", backing: 1.25, zoom: 2), base("base-noon-1.5x", backing: 1.5, zoom: 2)]
        return PlazaRenderEnv.only.map { only in list.filter { only.contains($0.name) } } ?? list
    }

    private static func makeAll() -> [PlazaRenderScene] {
        var out: [PlazaRenderScene] = [
            base("base-noon", backing: 1, zoom: 2, photo: true), base("base-noon-2x", backing: 2, zoom: 2),
            base("zoom-1", backing: 2, zoom: 1), base("zoom-4", backing: 2, zoom: 4),
            daylight("dusk", hour: 18, minute: 40), daylight("night", hour: 23, photo: true),
            season("summer", .summer), season("spring", .spring), season("autumn", .autumn), season("winter-snow", .winter, photo: true),
            edge("summer-edge", .summer), edge("spring-edge", .spring), edge("autumn-edge", .autumn),
            scene("winter-footprints", captures: [30, 120, 400]) { st in
                var o = Options(); o.season = .winter; o.me = TilePoint(x: 8, y: 10)
                let s = stage(o, on: st)
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
            hotSpring("hot-spring", .summer, zoom: 2, captures: [10, 60]),
            hotSpring("hot-spring-night", .summer, hour: 23, zoom: 2, captures: [10]),
            hotSpring("hot-spring-summer", .summer, zoom: 1, captures: [10]),
            hotSpring("hot-spring-spring", .spring, zoom: 1, captures: [10]),
            hotSpring("hot-spring-autumn", .autumn, zoom: 1, captures: [10]),
            hotSpring("hot-spring-winter", .winter, zoom: 1, captures: [10], photo: true),
            ice("ice-frozen") { _, _ in },
            ice("ice-breaking") { s, f in if f == 1 { s.scene.setIceBreak(iceBreak(s), hit: TilePoint(x: 9, y: 14)) } },
            ice("ice-refreeze") { s, f in
                if f == 1 { s.scene.setIceBreak(iceBreak(s), hit: TilePoint(x: 9, y: 14)) }
                if f >= 4 { s.clock.date = s.base.addingTimeInterval(PlazaIce.refreezeDelay + Double(f - 4) / 60) }
            },
            scene("tall-grass", captures: [5, 20, 50]) { st in
                var o = Options(); o.me = TilePoint(x: 12, y: 7)
                let s = stage(o, on: st)
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
            scene("dance", captures: [7, 23, 41]) { st in
                let s = stage(on: st)
                s.put(crowd(Options().me), looks: crowdLooks)
                return setup(s, photo: true) { f in
                    if f == 1 {
                        press(s, 2)   // D: my dance, the injected style is twirl
                        _ = s.scene.playDance(memberID: "ash", style: "bigHop")
                        _ = s.scene.playDance(memberID: "misty", style: "spin")
                    }
                }
            },
            scene("pray-wobble", captures: [7, 23, 41]) { st in
                var o = Options(); o.meLook = .egg
                let s = stage(o, on: st)
                s.put([member("e1", "Egg1", 21, 10), member("ash", "Ash", 17, 10)], looks: ["e1": .egg, "ash": .ash])
                return setup(s) { f in if f == 1 { s.scene.playPray(memberID: nil); s.scene.playPray(memberID: "e1") } }
            },
            scene("emotes", captures: [10]) { st in
                let s = stage(on: st)
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
            throwing("petal-balls", choice: .spring), throwing("leaf-balls", choice: .autumn),
            effect("jump-dust") { s in s.scene.playJump(memberID: nil); s.scene.playJump(memberID: "ash") },
            effect("tackle-impact") { s in s.scene.playTackle(by: "ash", on: nil, direction: .right) },
            effect("shutter") { s in s.scene.playShutterFlash() },
            effect("sparkle") { s in s.scene.playSparkle(memberID: nil); s.scene.playSparkle(memberID: "misty") },
            itemScene(),
            scene("board-marker", captures: [10, 40]) { st in
                var o = Options(); o.zoom = 1; o.me = TilePoint(x: 24, y: 8)
                let s = stage(o, on: st)
                s.put([member("ash", "Ash", 21, 9)], looks: crowdLooks)
                s.scene.setBoardMarker(visible: true)
                return setup(s)
            },
            scene("wet", captures: [10, 40]) { st in
                let s = stage(on: st)
                s.put(crowd(Options().me), looks: crowdLooks)
                s.scene.myActor.showWet()
                s.scene.memberActor("ash")?.showWet()
                return setup(s)
            },
            scene("background-hidden", captures: [10]) { st in
                let s = stage(on: st)
                s.put(crowd(Options().me), looks: crowdLooks)
                s.scene.setBackgroundHidden(true)
                return setup(s)
            },
            scene("photo-mode", captures: [10, 30]) { st in
                let s = stage(on: st)
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
            scene("member-leave", captures: [8, 16, 24, 32]) { st in
                var o = Options(); o.me = TilePoint(x: 12, y: 12)
                let s = stage(o, on: st)
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
            scene("pond-hop", captures: [4, 10, 16, 28]) { st in
                var o = Options(); o.zoom = 1; o.me = TilePoint(x: 14, y: 19)
                let s = stage(o, on: st)
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
            scene("lunges", captures: [3, 9, 15, 24]) { st in
                let s = stage(on: st)
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
        if let real = realSpritesScene?() { out.append(real) }
        if let only = PlazaRenderEnv.only { out = out.filter { only.contains($0.name) } }
        return out
    }
}
