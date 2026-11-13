import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 포켓몬 스프라이트를 런타임에 받아 로컬(Application Support)에 캐시. 레포/번들에 미포함.
actor SpriteStore {
    static let shared = SpriteStore()
    private static let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"
    private let itemBase = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/items"
    private var mem: [String: Data] = [:]
    private var memOrder: [String] = []   // LRU 순서(최근 접근이 뒤). 상한 초과 시 앞(오래된 것)부터 evict
    // 원본 PNG/GIF 바이트의 LRU 상한 — 도감 한 페이지(24칸)보다 넉넉히 유지하되,
    // 세션 중 종 변경으로 무한 누적되지 않게 한다. NSImage 캐시는 SpriteLoader 가 별도로 관리한다.
    private let memLimit = 64
    // Keys the server answered 404 for this session. A back sprite that does not exist is final (use the
    // front one); any other failure is transient and must be retried instead of settling on the front.
    private var confirmedMissing: Set<String> = []
    nonisolated let directory: URL

    init(directory: URL? = nil) {
        let d = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar/sprites")
        self.directory = d
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }

    /// 기본 폼은 구캐시 키 그대로 유지. 다른 폼은 폼·이로치·애니메이션을 모두 구분한다.
    /// `back` sprites (the companion turned away) get their own `-back` segment; front keys are unchanged.
    static func cacheKey(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm? = nil,
                         back: Bool = false) -> String {
        let name = PokemonForm.assetName(speciesID: speciesID, form: form)
        return "\(name)-\(back ? "back-" : "")\(shiny ? "sh" : "")\(animated ? "a" : "s")"
    }

    /// PokeAPI names form GIFs `201-b`/`492-sky`; static PNGs of separate varieties use the variety
    /// id (`10006.png`). Cache files keep the `<id>-<form>` name either way.
    /// Back sprites sit in a `back/` folder in front of `shiny/`, for both GIFs and PNGs.
    static func spriteURL(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm? = nil,
                          back: Bool = false) -> URL {
        let name = animated ? PokemonForm.assetName(speciesID: speciesID, form: form)
                            : PokemonForm.staticAssetName(speciesID: speciesID, form: form)
        let path = animated ? "versions/generation-v/black-white/animated/" : ""
        let facing = back ? "back/" : ""
        let color = shiny ? "shiny/" : ""
        let ext = animated ? "gif" : "png"
        return URL(string: "\(base)/\(path)\(facing)\(color)\(name).\(ext)")!
    }

    func data(speciesID: Int, animated: Bool, shiny: Bool = false, form: PokemonForm? = nil,
              back: Bool = false) async -> Data? {
        if animated, !PokemonAssets.hasAnimatedSprite(speciesID: speciesID) { return nil }
        let key = Self.cacheKey(speciesID: speciesID, animated: animated, shiny: shiny, form: form, back: back)
        if let d = mem[key] { touch(key); return d }
        let ext = animated ? "gif" : "png"
        let file = directory.appendingPathComponent("\(key).\(ext)")
        if let d = try? Data(contentsOf: file) { remember(key, d); return d }
        if confirmedMissing.contains(key) { return nil }
        let url = Self.spriteURL(speciesID: speciesID, animated: animated, shiny: shiny, form: form, back: back)
        guard let (d, resp) = try? await URLSession.shared.data(from: url) else { return nil }
        let status = (resp as? HTTPURLResponse)?.statusCode
        if back, status == 404 { confirmedMissing.insert(key) }
        guard status == 200, !d.isEmpty else { return nil }
        try? d.write(to: file, options: .atomic)   // torn write 방지 — 크래시/강제종료 시 손상 캐시가 남지 않게
        remember(key, d)
        return d
    }

    /// True once the server answered 404 for this sprite in this session.
    func isConfirmedMissing(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm?, back: Bool) -> Bool {
        confirmedMissing.contains(Self.cacheKey(speciesID: speciesID, animated: animated, shiny: shiny,
                                                form: form, back: back))
    }

    /// 아이템 스프라이트(정적 PNG, 이름 기반). 포켓몬과 같은 메모리/디스크 캐시 사용(키 "item-<name>",
    /// 포켓몬 파일 "<id>-..." 과 안 겹침). 미제공(404)/오프라인이면 nil → 뷰가 이모지로 폴백.
    func data(itemName: String) async -> Data? {
        let key = "item-\(itemName)"
        if let d = mem[key] { touch(key); return d }
        let file = directory.appendingPathComponent("\(key).png")
        if let d = try? Data(contentsOf: file) { remember(key, d); return d }
        guard let url = URL(string: "\(itemBase)/\(itemName).png"),
              let (d, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(key, d)
        return d
    }

    /// 알 스프라이트(정적, pokemon/egg.png) — 애니메이션 알은 없음. 포켓몬/아이템과 같은 메모리·디스크 캐시(키 "egg").
    func eggData() async -> Data? {
        let key = "egg"
        if let d = mem[key] { touch(key); return d }
        let file = directory.appendingPathComponent("egg.png")
        if let d = try? Data(contentsOf: file) { remember(key, d); return d }
        guard let url = URL(string: "\(Self.base)/egg.png"),
              let (d, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(key, d)
        return d
    }

    /// in-memory 캐시에 넣고 LRU 상한 유지(#H1) — 세션 중 종이 여러 번 바뀌어도 무한 성장 방지.
    private func remember(_ key: String, _ data: Data) {
        mem[key] = data
        touch(key)
        while memOrder.count > memLimit {
            let old = memOrder.removeFirst()
            mem.removeValue(forKey: old)
        }
    }
    /// 접근/삽입 키를 최근(뒤)으로 이동 — 활성 종이 evict 되지 않게 하는 LRU.
    private func touch(_ key: String) {
        if let i = memOrder.firstIndex(of: key) { memOrder.remove(at: i) }
        memOrder.append(key)
    }
}
