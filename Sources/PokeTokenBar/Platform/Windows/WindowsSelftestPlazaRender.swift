#if os(Windows)
import Foundation

/// Stage 6 Task 4: the scene renderer in the release build, offscreen on WARP (no window). D19's busy case: twelve
/// teammates walking around a lit campfire on a winter night while fireworks go up, 60 warm-up frames, then 240 measured.
/// `plaza.renderCost` fails when the main thread's scene update + flatten + command building takes more than D19's 4 ms per
/// frame (median); recording + EndDraw and WARP's raster time are reported, not judged. The teammates' pictures are a
/// FIXTURE (a plain block of bytes standing in for a sprite: the cost does not depend on what the texels show).
/// `plaza.renderCostTree` is the same busy case at the big tree with it shaking: a hit from me (levels 1 to 3, the level 3 one dropping a
/// mint) and one from a teammate at (15,10) every 20 frames, so the leaves, dust, star and falling item are all in play.
/// Runs after the idle window: it loads Direct3D and WARP's worker threads.
extension WindowsSelftest {
    @MainActor static func plazaRenderChecks(_ r: Recorder) async {
        let device: WinGfxDevice
        switch WinGfxDevice.make(forceWarp: true) {
        case .success(let d): device = d
        case .failure(let e):
            r.add("plaza.renderCost", false, "\(e)")
            r.add("plaza.renderCostSpring", false, "\(e)")
            r.add("plaza.renderCostTree", false, "\(e)")
            return
        }
        // The busy case at the first campfire seat, then the same busy case with the hot spring in view (steam up, every
        // second swimmer red).
        let seat = PlazaCampfire.seats.first
        let campfireMe = seat?.tile ?? TilePoint(x: 19, y: 10)
        let campfireMembers: [PlazaSceneMember] = (0..<12).map { i in
            PlazaSceneMember(memberID: "m\(i)", nickname: "Member \(i)", isAway: false,
                             tile: TilePoint(x: campfireMe.x - 4 + (i % 6) * 2, y: campfireMe.y - 3 + (i / 6) * 5), facing: .down, isWalking: true)
        }
        await measure(r, device: device, name: "plaza.renderCost", me: campfireMe, sit: seat, members: campfireMembers)
        let springMembers: [PlazaSceneMember] = (0..<12).map { i in
            var m = PlazaSceneMember(memberID: "m\(i)", nickname: "Member \(i)", isAway: false,
                                     tile: TilePoint(x: 32 + i % 6, y: i < 6 ? 15 : 18), facing: .down, isWalking: true)
            m.isFlushed = i % 2 == 1
            return m
        }
        await measure(r, device: device, name: "plaza.renderCostSpring", me: TilePoint(x: 31, y: 17), sit: nil, members: springMembers)
        // The big tree under me, shaking: eleven teammates around it (x 13...24 on rows 12 and 7; none on a tree tile, those on row 7
        // behind the narrow top stand behind it) and one standing at (15,10) who hits it.
        var treeMembers: [PlazaSceneMember] = (0..<11).map { i in
            PlazaSceneMember(memberID: "m\(i)", nickname: "Member \(i)", isAway: false,
                             tile: TilePoint(x: 13 + i, y: i % 2 == 0 ? 12 : 7), facing: .down, isWalking: true)
        }
        treeMembers.append(PlazaSceneMember(memberID: "m11", nickname: "Member 11", isAway: false, tile: TilePoint(x: 15, y: 10), facing: .right, isWalking: false))
        await measure(r, device: device, name: "plaza.renderCostTree", me: TilePoint(x: 17, y: 12), sit: nil, members: treeMembers)
        // The documentation captures: the same offscreen renderer on a summer noon, each written next to the other captures.
        let shotMembers: [PlazaSceneMember] = [
            PlazaSceneMember(memberID: "a", nickname: "Ash", isAway: false, tile: TilePoint(x: 33, y: 16), facing: .right, isWalking: false),
            PlazaSceneMember(memberID: "b", nickname: "Misty", isAway: false, tile: TilePoint(x: 37, y: 18), facing: .left, isWalking: false),
            PlazaSceneMember(memberID: "c", nickname: "Brock", isAway: false, tile: TilePoint(x: 35, y: 21), facing: .up, isWalking: false),
        ].enumerated().map { i, m in var m = m; m.isFlushed = i == 0; return m }
        await shoot(r, device: device, name: "plaza.shotSpring", file: "plaza-hot-spring.png", me: TilePoint(x: 35, y: 17), members: shotMembers) { _, _ in }
        // The big tree at the moment of the hit that drops a mint (a tree's fifth of the day), 18 frames (0.3 s) after the hit starts:
        // the leaves burst at 0.2 s (contact 0.1 s plus the 0.1 s hit stop), so the bend, the leaves and the star all show;
        // teammates stand beside and behind it.
        let shotTreeMembers: [PlazaSceneMember] = [
            PlazaSceneMember(memberID: "a", nickname: "Ash", isAway: false, tile: TilePoint(x: 15, y: 10), facing: .right, isWalking: false),
            PlazaSceneMember(memberID: "b", nickname: "Brock", isAway: false, tile: TilePoint(x: 19, y: 10), facing: .left, isWalking: false),
            PlazaSceneMember(memberID: "c", nickname: "Misty", isAway: false, tile: TilePoint(x: 17, y: 7), facing: .down, isWalking: false),
        ]
        await shoot(r, device: device, name: "plaza.shotTree", file: "plaza-big-tree.png", me: TilePoint(x: 17, y: 11), members: shotTreeMembers, frames: 78) { scene, f in
            if f == 1 { scene.face(.up) }
            if f == 60 { scene.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint) }
        }
        // The second big tree (tiles x41-43, y25-27) with the mint of a tree's fifth hit bounced out beside me, 40 frames after the hit.
        let shotTwoTreesMembers: [PlazaSceneMember] = [
            PlazaSceneMember(memberID: "a", nickname: "Ash", isAway: false, tile: TilePoint(x: 40, y: 26), facing: .right, isWalking: false),
            PlazaSceneMember(memberID: "b", nickname: "Misty", isAway: false, tile: TilePoint(x: 42, y: 24), facing: .down, isWalking: false),
            PlazaSceneMember(memberID: "c", nickname: "Brock", isAway: false, tile: TilePoint(x: 38, y: 27), facing: .left, isWalking: false),
        ]
        await shoot(r, device: device, name: "plaza.shotTwoTrees", file: "plaza-two-trees.png", me: TilePoint(x: 42, y: 28), members: shotTwoTreesMembers, frames: 40) { scene, f in
            if f == 1 { scene.face(.up); scene.playTreeHit(tree: 1, by: nil, direction: .up, level: 3, drop: .mint) }
        }
        // A pass-the-bomb round in progress: the bomb (about to go off) over Misty's head, teammates around me.
        let shotBombMembers: [PlazaSceneMember] = [
            PlazaSceneMember(memberID: "a", nickname: "Ash", isAway: false, tile: TilePoint(x: 15, y: 13), facing: .right, isWalking: false),
            PlazaSceneMember(memberID: "b", nickname: "Misty", isAway: false, tile: TilePoint(x: 19, y: 15), facing: .left, isWalking: false),
            PlazaSceneMember(memberID: "c", nickname: "Brock", isAway: false, tile: TilePoint(x: 17, y: 17), facing: .up, isWalking: false),
        ]
        await shoot(r, device: device, name: "plaza.shotBomb", file: "plaza-bomb-game.png", me: TilePoint(x: 17, y: 14), members: shotBombMembers, frames: 30) { scene, f in
            if f == 1 { scene.setBomb(holder: "b", isMe: false, urgent: true) }
        }
    }

    /// One documentation capture: `me` and `members` (FIXTURE blocks for sprites) in the summer plaza at noon, `script` called
    /// before each of `total` frames (1-based), the last frame written as `file`. The shot only fails when no frame can be read.
    @MainActor private static func shoot(_ r: Recorder, device: WinGfxDevice, name: String, file: String, me: TilePoint,
                                          members: [PlazaSceneMember], frames total: Int = 120, script: (PlazaScene, Int) -> Void) async {
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.setBackingScale(2)
        guard case .success(let surface) = WinGfxSurface.offscreen(device: device, width: 1280, height: 960) else {
            r.add(name, false, "no offscreen surface: \(WinPlazaCodecs.lastError())")
            return
        }
        let renderer = WinPlazaRenderer(surface: surface)
        let map = PlazaMapData.map
        let grass = PlatformPlaza.tallGrassArt()
        let mapImage = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: grass) } ?? PlazaTileArt.plainGrassImage(map)
        let scene = PlazaScene(map: map, mapImage: mapImage, start: me, zoom: 2, nickname: "Me", tallGrass: grass, pondVisuals: true,
                               iceArt: PlatformPlaza.iceArt(), stage: stage)
        scene.size = CGSize(width: 640, height: 480)
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)) ?? Date()
        var now = base
        scene.now = { now }
        scene.currentModifiers = { [] }
        scene.seasonChoice = .summer
        // FIXTURE: a plain block of one colour per person stands in for each sprite.
        func blockFrames(_ c: PlazaRGBA) -> PlazaCharacterFrames {
            var block = PlazaBitmap(width: 28, height: 32)
            for y in 2..<30 { for x in 3..<25 { block[x, y] = c } }
            return PlazaCharacterFrames(front: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2)],
                                        back: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2)])
        }
        let colours = [PlazaRGBA(r: 90, g: 130, b: 220, a: 255), PlazaRGBA(r: 90, g: 190, b: 120, a: 255), PlazaRGBA(r: 220, g: 190, b: 80, a: 255)]
        scene.setCharacter(blockFrames(PlazaRGBA(r: 200, g: 80, b: 80, a: 255)))
        scene.applyMembers(members)
        for (i, m) in members.enumerated() { scene.setMemberFrames(m.memberID, blockFrames(colours[i % colours.count])) }
        let clockBase = 1000.0
        for _ in 0..<15 { stage.tick(at: clockBase) }
        for f in 1...total {
            now = base.addingTimeInterval(Double(f) / 60)
            script(scene, f)
            stage.tick(at: clockBase + Double(f) / 60)
            _ = renderer.drawIfNeeded(stage: stage)
            device.finish()
        }
        guard let rgba = surface.readRGBA() else { r.add(name, false, "no frame readback"); return }
        r.add(name, writeFrame(rgba, 1280, 960, file) == 0, "\(file) 1280x960, summer noon, a FIXTURE block per person for sprites, steam=\(scene.isSteamShown) tree=\(scene.isTreeShown)")
    }

    /// One render-cost case: `me` (sitting at `sit` when given) and `members` on the winter night, 60 warm-up frames, then
    /// 240 measured. Members step one tile sideways every 20 frames (into or out of the spring, both are fine).
    @MainActor private static func measure(_ r: Recorder, device: WinGfxDevice, name: String, me: TilePoint,
                                            sit seat: PlazaCampfire.Seat?, members start: [PlazaSceneMember]) async {
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.setBackingScale(2)
        guard case .success(let surface) = WinGfxSurface.offscreen(device: device, width: 1280, height: 960) else {
            r.add(name, false, "no offscreen surface: \(WinPlazaCodecs.lastError())")
            return
        }
        let renderer = WinPlazaRenderer(surface: surface)
        let spring = name == "plaza.renderCostSpring", tree = name == "plaza.renderCostTree"
        let map = PlazaMapData.map
        let grass = PlatformPlaza.tallGrassArt()
        let mapImage = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: grass) } ?? PlazaTileArt.plainGrassImage(map)
        let scene = PlazaScene(map: map, mapImage: mapImage, start: me, zoom: 2, nickname: "Me", tallGrass: grass, pondVisuals: true,
                               iceArt: PlatformPlaza.iceArt(), stage: stage)
        scene.size = CGSize(width: 640, height: 480)
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 23)) ?? Date()
        var now = base
        scene.now = { now }
        scene.currentModifiers = { [] }
        scene.seasonChoice = .winter
        scene.refreshSnowDay()
        var block = PlazaBitmap(width: 28, height: 32)   // FIXTURE
        for y in 2..<30 { for x in 3..<25 { block[x, y] = PlazaRGBA(r: 200, g: 120, b: 80, a: 255) } }
        let frames = PlazaCharacterFrames(front: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2)],
                                          back: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2)])
        scene.setCharacter(frames)
        if let seat { scene.sit(at: seat) }
        var members = start
        scene.applyMembers(members)
        for m in members { scene.setMemberFrames(m.memberID, frames) }
        scene.campfireLit = true
        scene.setCampfireTimer("24:59")

        func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
        let clockBase = 1000.0, warm = 60, measured = 240
        for _ in 0..<15 { stage.tick(at: clockBase) }
        var cpu: [Double] = [], submit: [Double] = [], raster: [Double] = []
        var clean = 0
        var mostLeaves = 0   // the busiest the tree got: the hits really animated it (`isTreeShown` is true for a still tree too)
        for f in 1...(warm + measured) {
            now = base.addingTimeInterval(Double(f) / 60)
            if f % 20 == 1 {
                for i in members.indices {
                    guard let tile = members[i].tile, members[i].isWalking else { continue }   // a standing teammate (the tree's hitter) stays
                    var moved = PlazaSceneMember(memberID: members[i].memberID, nickname: members[i].nickname, isAway: false,
                                                 tile: TilePoint(x: tile.x + ((f / 20 + i) % 2 == 0 ? 1 : -1), y: tile.y),
                                                 facing: members[i].facing, isWalking: true)
                    moved.isFlushed = members[i].isFlushed
                    members[i] = moved
                }
                scene.applyMembers(members)
            }
            if tree, f % 20 == 1 {
                let n = f / 20
                scene.playTreeHit(by: nil, direction: .up, level: 1 + n % 3, drop: n % 3 == 2 ? .mint : nil)
                scene.playTreeHit(by: "m11", direction: .right, level: 1 + (n + 1) % 3, drop: nil)
            }
            if f % 45 == 1 { _ = scene.playFirework(memberID: "m\((f / 45) % 12)", style: ["ring", "willow", "heartShape"][(f / 45) % 3]) }
            let t0 = seconds()
            stage.tick(at: clockBase + Double(f) / 60)
            let t1 = seconds()
            let result = renderer.drawIfNeeded(stage: stage)
            let t2 = seconds()
            device.finish()
            let t3 = seconds()
            mostLeaves = max(mostLeaves, scene.treeLeafCount)
            guard f > warm else { continue }
            guard result == .drawn else { clean += 1; continue }
            cpu.append(t1 - t0 + renderer.stats.buildSeconds)
            submit.append(renderer.stats.submitSeconds)
            raster.append(t3 - t2)
        }
        func ms(_ v: [Double], _ p: Double) -> String {
            guard !v.isEmpty else { return "-" }
            return String(format: "%.2f", v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] * 1000)
        }
        let median = cpu.isEmpty ? Double.infinity : cpu.sorted()[cpu.count / 2] * 1000
        let st = renderer.stats
        r.add(name, median <= 4 && st.failedFrames == 0 && (!spring || scene.isSteamShown) && (!tree || (scene.isTreeShown && mostLeaves > 0)),
              (spring ? "hot spring in view steam=\(scene.isSteamShown) " : "") + (tree ? "tree=\(scene.isTreeShown) mostLeaves=\(mostLeaves) " : "") + "rush-hour, release, offscreen WARP 1280x960 (\(device.adapter)): update+flatten+build p50=\(ms(cpu, 0.5)) p95=\(ms(cpu, 0.95)) ms "
                + "(D19 budget 4 ms, median judged); record+EndDraw p50=\(ms(submit, 0.5)) ms; WARP raster p50=\(ms(raster, 0.5)) p95=\(ms(raster, 0.95)) ms; "
                + "drawn=\(cpu.count) clean=\(clean) of \(measured); commands=\(st.commands) bitmaps=\(st.bitmapDraws) colours=\(st.colorDraws) "
                + "effects=\(st.effectDraws) failedFrames=\(st.failedFrames) liveBitmaps=\(device.stats.liveBitmaps) (\(device.stats.liveBitmapBytes / 1024) KB)")
    }
}
#endif
