import Foundation
@testable import PokeTokenBar

/// Stage 6 Task 4's preview of the render harness (the whole harness becomes shared in Task 15): five of
/// `PlazaRenderScenes`' scenes built with the same `PlazaScene` calls, the same frame-pure clock and the same synthetic
/// characters, from FIXTURE BYTES only (no Pokémon art is committed), plus `rush-hour` for the frame cost. Shared code, so
/// the Mac and Windows build the same trees and their `PlazaTreeDump`s can be compared line by line.
///
/// Driving rule (the Mac harness's `PlazaRenderRun.run`): 15 updates at t = 0, then per frame `step(frame)` and one update
/// at frame / 60 s; at a capture frame 15 more updates at the same time. Times are `clockBase + t`.
@MainActor
enum PlazaPreviewScenes {
    struct Scene {
        let name: String
        let backing: CGFloat
        let captures: [Int]
        let build: @MainActor (_ stage: any PlazaStage) -> Setup
    }

    struct Setup {
        let scene: PlazaScene
        let step: @MainActor (_ frame: Int) -> Void
    }

    static let viewport = CGSize(width: 640, height: 480)
    static let clockBase: TimeInterval = 1000
    static let warmUpUpdates = 15
    static let map = PlazaMapData.map

    // MARK: Synthetic characters (fixture bytes: `PlazaRenderScenes.body`, the same pixels)

    enum Look: Hashable { case me, ash, brock, misty, dawn }

    static func body(_ look: Look, front: Bool, step: Int) -> PlazaImage {
        let (w, h) = (28, 32)
        let colour: (UInt8, UInt8, UInt8) = switch look {
        case .me: (230, 80, 60)
        case .ash: (60, 120, 230)
        case .brock: (200, 160, 60)
        case .misty: (70, 200, 120)
        case .dawn: (200, 90, 200)
        }
        var bitmap = PlazaBitmap(width: w, height: h)
        func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            bitmap[x, y] = PlazaRGBA(r: c.0, g: c.1, b: c.2, a: 255)
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
        if front {
            put(9, 11, dark); put(18, 11, dark); put(13, 17, dark); put(14, 17, dark)
        } else {
            for x in 8..<20 { put(x, 9, dark) }
        }
        put(step == 0 ? 7 : 20, h - 3, dark); put(step == 0 ? 7 : 20, h - 2, dark)
        return PlazaImage(bitmap: bitmap)
    }

    static func frames(_ look: Look) -> PlazaCharacterFrames {
        let front = (0..<2).map { PlazaFrame(image: body(look, front: true, step: $0), delay: 0.2) }
        let back = (0..<2).map { PlazaFrame(image: body(look, front: false, step: $0), delay: 0.2) }
        return PlazaCharacterFrames(front: front, back: back)
    }

    // MARK: Art (the bundled sheets through PlatformPlaza; on Windows from WinPlazaAssets)

    private static var summerMap: PlazaImage?
    private static var tallGrass: PlazaTallGrassArt??
    private static var iceArt: PlazaIceArt?
    private static var looks: [PlazaSeason: PlazaSnowLook?] = [:]

    static func seasonLook(_ season: PlazaSeason) -> PlazaSnowLook? {
        if let built = looks[season] { return built }
        var look: PlazaSnowLook?
        if season != .summer, let sheet = PlatformPlaza.tileSheet() {
            let art = PlatformPlaza.tallGrassSheet().map { PlazaSeasonSheet.tallGrass($0, season: season) }.flatMap(PlazaTallGrassArt.init(sheet:))
            look = PlazaSnowLook(mapImage: PlazaTileArt.mapImage(map, sheet: PlazaSeasonSheet.tiles(sheet, season: season), tallGrass: art), tallGrass: art)
        }
        looks[season] = .some(look)
        return look
    }

    // MARK: Stage

    struct Options {
        var me = TilePoint(x: 19, y: 10)
        var zoom = 2
        var backing: CGFloat = 2
        var season = PlazaSeasonChoice.summer
        var hour = 12
        var minute = 0
    }

    @MainActor final class Rig {
        let scene: PlazaScene
        let base: Date
        var date: Date
        var members: [PlazaSceneMember] = []
        var applied = Set<String>()
        var memberLooks: [String: Look] = [:]

        init(scene: PlazaScene, base: Date) {
            self.scene = scene
            self.base = base
            date = base
        }

        func put(_ list: [PlazaSceneMember], looks: [String: Look] = [:]) {
            members = list
            for (k, v) in looks { memberLooks[k] = v }
            scene.applyMembers(list)
            for m in list where !applied.contains(m.memberID) {
                applied.insert(m.memberID)
                scene.setMemberFrames(m.memberID, PlazaPreviewScenes.frames(memberLooks[m.memberID] ?? .ash))
            }
        }

        func move(_ id: String, to tile: TilePoint, walking: Bool) {
            guard let i = members.firstIndex(where: { $0.memberID == id }) else { return }
            let m = members[i]
            var n = PlazaSceneMember(memberID: m.memberID, nickname: m.nickname, isAway: m.isAway, tile: tile, facing: m.facing, isWalking: walking)
            n.isIdle = m.isIdle; n.nameColor = m.nameColor; n.isRunning = m.isRunning
            n.isDiving = m.isDiving; n.evolutionStage = m.evolutionStage; n.nature = m.nature
            var list = members
            list[i] = n
            put(list)
        }

        func moveDiving(_ id: String, diving: Bool) {
            guard let i = members.firstIndex(where: { $0.memberID == id }) else { return }
            var list = members
            list[i].isDiving = diving
            put(list)
        }
    }

    static func member(_ id: String, _ name: String, _ x: Int, _ y: Int, facing: PlazaDirection = .down, walking: Bool = false,
                       diving: Bool = false) -> PlazaSceneMember {
        var m = PlazaSceneMember(memberID: id, nickname: name, isAway: false, tile: TilePoint(x: x, y: y), facing: facing, isWalking: walking)
        m.isDiving = diving
        return m
    }

    static func crowd(_ me: TilePoint) -> [PlazaSceneMember] {
        [member("ash", "Ash", me.x + 2, me.y, facing: .left),
         member("brock", "Brock", me.x - 2, me.y + 1, facing: .down, walking: true),
         member("misty", "Misty", me.x + 1, me.y - 2, facing: .up),
         member("dawn", "Dawn", me.x + 3, me.y + 2, facing: .right, walking: true)]
    }

    static let crowdLooks: [String: Look] = ["ash": .ash, "brock": .brock, "misty": .misty, "dawn": .dawn]

    static func rig(_ o: Options, stage: any PlazaStage) -> Rig {
        if summerMap == nil {
            let grass = PlatformPlaza.tallGrassArt()
            tallGrass = .some(grass)
            iceArt = PlatformPlaza.iceArt()
            summerMap = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: grass) } ?? PlazaTileArt.plainGrassImage(map)
        }
        stage.size = CGSize(width: 960, height: 640)   // `PlatformPlaza.makeStage`'s size, then the viewport, as the harness
        let scene = PlazaScene(map: map, mapImage: summerMap!, start: o.me, zoom: o.zoom, nickname: "Me",
                               tallGrass: tallGrass ?? nil, pondVisuals: true, iceArt: iceArt, stage: stage)
        scene.backingOverride = o.backing
        scene.size = viewport
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: o.hour, minute: o.minute))!
        let rig = Rig(scene: scene, base: base)
        scene.now = { [weak rig] in rig?.date ?? base }
        scene.seasonLook = { seasonLook($0) }
        scene.pickDanceStyle = { _ in .twirl }
        scene.currentModifiers = { [] }
        scene.seasonChoice = o.season
        scene.refreshSnowDay()
        scene.setCharacter(frames(.me))
        return rig
    }

    private static func setup(_ r: Rig, _ step: @escaping @MainActor (Int) -> Void = { _ in }) -> Setup {
        Setup(scene: r.scene, step: { frame in
            r.date = r.base.addingTimeInterval(Double(frame) / 60)
            step(frame)
        })
    }

    static func press(_ r: Rig, _ code: UInt16) { r.scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false) }
    static func release(_ r: Rig, _ code: UInt16) { r.scene.handleKeyUp(keyCode: code) }
    static let right: UInt16 = 124

    // MARK: Scenes (as `PlazaRenderScenes`)

    static let all: [Scene] = [
        Scene(name: "base-noon", backing: 1, captures: [10, 40, 90]) { stage in
            var o = Options(); o.backing = 1
            let r = rig(o, stage: stage)
            r.put(crowd(o.me), looks: crowdLooks)
            return setup(r) { f in
                switch f {
                case 1: r.move("brock", to: TilePoint(x: 17, y: 13), walking: true); r.move("dawn", to: TilePoint(x: 22, y: 14), walking: true)
                case 30: press(r, right)
                case 60: release(r, right)
                default: break
                }
            }
        },
        Scene(name: "dusk", backing: 2, captures: [10]) { stage in
            var o = Options(); o.hour = 18; o.minute = 40
            let r = rig(o, stage: stage)
            r.put(crowd(o.me), looks: crowdLooks)
            return setup(r)
        },
        Scene(name: "campfire-lit-night", backing: 2, captures: [10, 37, 64]) { stage in
            var o = Options(); o.hour = 23
            o.me = PlazaCampfire.seats[0].tile
            let r = rig(o, stage: stage)
            r.scene.sit(at: PlazaCampfire.seats[0])
            let seats = PlazaCampfire.seats
            r.put([member("ash", "Ash", seats[1].tile.x, seats[1].tile.y, facing: seats[1].facing),
                   member("brock", "Brock", seats[2].tile.x, seats[2].tile.y, facing: seats[2].facing),
                   member("misty", "Misty", seats[4].tile.x, seats[4].tile.y, facing: seats[4].facing)], looks: crowdLooks)
            r.scene.campfireLit = true
            r.scene.setCampfireTimer("24:59")
            return setup(r)
        },
        Scene(name: "pond-swim", backing: 2, captures: [5, 20, 45]) { stage in
            var o = Options(); o.me = TilePoint(x: 9, y: 14)
            let r = rig(o, stage: stage)
            r.put([member("ash", "Ash", 7, 14, facing: .right), member("brock", "Brock", 11, 14, diving: true),
                   member("misty", "Misty", 10, 12, facing: .down), member("dawn", "Dawn", 8, 13, facing: .down, walking: true)],
                  looks: crowdLooks)
            return setup(r) { f in
                switch f {
                case 1: r.move("dawn", to: TilePoint(x: 8, y: 14), walking: true)
                case 3: r.scene.playJump(memberID: nil)
                case 12: r.moveDiving("brock", diving: false)
                case 14: r.scene.setDiving(true)
                case 30: r.move("ash", to: TilePoint(x: 6, y: 14), walking: true)
                default: break
                }
            }
        },
        Scene(name: "dance", backing: 2, captures: [7, 23, 41]) { stage in
            let r = rig(Options(), stage: stage)
            r.put(crowd(Options().me), looks: crowdLooks)
            return setup(r) { f in
                if f == 1 {
                    press(r, 2)   // D: my dance (the injected style is twirl)
                    _ = r.scene.playDance(memberID: "ash", style: "bigHop")
                    _ = r.scene.playDance(memberID: "misty", style: "spin")
                }
            }
        },
    ]

    /// D19's busy case: twelve teammates walking around a lit campfire at night in winter (snow), fireworks going up.
    static let rushHour = Scene(name: "rush-hour", backing: 2, captures: [30, 120]) { stage in
        var o = Options(); o.hour = 23; o.season = .winter
        o.me = PlazaCampfire.seats[0].tile
        let r = rig(o, stage: stage)
        let looks: [Look] = [.ash, .brock, .misty, .dawn]
        let origin = o.me
        var list: [PlazaSceneMember] = []
        var memberLooks: [String: Look] = [:]
        for i in 0..<12 {
            let id = "m\(i)"
            list.append(member(id, "Member \(i)", origin.x - 4 + (i % 6) * 2, origin.y - 3 + (i / 6) * 5, facing: .down, walking: true))
            memberLooks[id] = looks[i % looks.count]
        }
        r.put(list, looks: memberLooks)
        r.scene.campfireLit = true
        r.scene.setCampfireTimer("24:59")
        return setup(r) { f in
            if f % 20 == 1 {   // everybody takes a step, left and right in turn
                for i in 0..<12 {
                    let m = r.members[i]
                    r.move(m.memberID, to: TilePoint(x: m.tile.x + ((f / 20 + i) % 2 == 0 ? 1 : -1), y: m.tile.y), walking: true)
                }
            }
            if f % 45 == 1 { _ = r.scene.playFirework(memberID: "m\((f / 45) % 12)", style: ["ring", "willow", "heartShape"][(f / 45) % 3]) }
        }
    }

    // MARK: Driving

    /// Runs a scene to each capture frame and hands the capture to `capture` (after the harness's 15 same-time updates).
    static func run(_ scene: Scene, stage: any PlazaStage, capture: (_ frame: Int, _ setup: Setup) async throws -> Void) async rethrows {
        let setup = scene.build(stage)
        setup.step(0)
        for _ in 0..<warmUpUpdates { setup.scene.stageUpdate(clockBase) }
        let last = scene.captures.max() ?? 0
        guard last > 0 else { return }
        for frame in 1...last {
            setup.step(frame)
            let t = clockBase + Double(frame) / 60
            setup.scene.stageUpdate(t)
            if scene.captures.contains(frame) {
                for _ in 0..<warmUpUpdates { setup.scene.stageUpdate(t) }
                try await capture(frame, setup)
            }
        }
    }

    /// The shared dump the harness writes (`PlazaTreeDump`, the harness's class names).
    static func dump(_ setup: Setup) -> String {
        PlazaTreeDump.lines(root: setup.scene.root, camera: setup.scene.stage.camera,
                            classNames: PlazaTreeDump.classNames(of: setup.scene)).joined(separator: "\n") + "\n"
    }
}
