import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 부화 후보 — 진화라인 시작점(base) 종과 공식 희귀도.
struct BaseSpecies: Sendable, Codable, Equatable {
    let id: Int
    let captureRate: Int    // 3(뮤츠급)~255(캐터피급), 공식 희귀도 신호
}

/// 포켓몬 라인 데이터 제공(주입 가능 — 테스트는 스텁 사용).
protocol PokeProviding: Sendable {
    func line(baseSpeciesID: Int) async throws -> EvoLine
    /// 1~5세대 base 전체 인덱스 (GraphQL 1쿼리, 디스크 캐시).
    func baseSpeciesIndex() async throws -> [BaseSpecies]
    /// 단일 종이 base(진화 시작점)면 BaseSpecies, 아니면 nil.
    /// GraphQL 인덱스 엔드포인트 장애 시 REST(pokemon-species)로 부화 후보를 뽑는 폴백용.
    func baseSpecies(id: Int) async throws -> BaseSpecies?
}

/// Separate from `PokeProviding` so existing evolution-only test doubles stay small.
protocol PokemonDetailProviding: Sendable {
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails
}

/// PokéAPI 클라이언트 — 종/진화체인을 런타임 fetch + 파싱. 포켓몬 데이터는 레포에 번들하지 않는다.
/// species 응답은 actor 캐시(다국어 이름 재사용).
actor PokeAPIClient: PokeProviding, PokemonDetailProviding {
    static let shared = PokeAPIClient()
    private let base = URL(string: "https://pokeapi.co/api/v2")!
    static var langCodes: [String] { AppLanguage.allCases.flatMap(\.apiCodes) }
    private var speciesCache: [Int: SpeciesDTO] = [:]
    private var lineCache: [Int: EvoLine] = [:]   // 프리패칭 → 부화 순간 네트워크 0
    private var detailsCache: [Int: PokemonDetails] = [:]

    private static let detailsDirectory: URL = {
        let dir = AppStatePaths.directory().appendingPathComponent("pokemon-details-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private struct DetailSnapshot: Codable {
        let fetchedAt: Date
        let details: PokemonDetails
    }

    /// Default-form battle metadata. Memory → 30-day disk cache → REST, with stale disk fallback offline.
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        if let cached = detailsCache[speciesID] { return cached }
        let file = Self.detailsDirectory.appendingPathComponent("\(speciesID).json")
        let disk = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode(DetailSnapshot.self, from: $0) }
        if let disk, Date().timeIntervalSince(disk.fetchedAt) < 30 * 86400 {
            detailsCache[speciesID] = disk.details
            return disk.details
        }
        do {
            let dto: PokemonDTO = try await get(base.appendingPathComponent("pokemon/\(speciesID)"))
            let speciesDTO = try await species(speciesID)
            let details = PokemonDetails(
                speciesID: speciesID,
                name: dto.name,
                height: dto.height,
                weight: dto.weight,
                baseExperience: dto.base_experience,
                genderRate: speciesDTO.gender_rate ?? -1,
                types: dto.types.sorted { $0.slot < $1.slot }.map { $0.type.name },
                baseStats: Dictionary(uniqueKeysWithValues: dto.stats.map { ($0.stat.name, $0.base_stat) }),
                abilities: dto.abilities.map {
                    PokemonAbilityOption(name: $0.ability.name, slot: $0.slot, isHidden: $0.is_hidden)
                }.sorted { $0.slot < $1.slot },
                moves: Self.normalizedMoves(dto.moves))
            detailsCache[speciesID] = details
            if let data = try? JSONEncoder().encode(DetailSnapshot(fetchedAt: Date(), details: details)) {
                try? data.write(to: file, options: .atomic)
            }
            return details
        } catch {
            if let disk {
                detailsCache[speciesID] = disk.details
                return disk.details
            }
            throw error
        }
    }

    /// Reduce PokéAPI's cross-generation move history at the trust boundary, before it reaches
    /// either memory or disk. Moves absent from the supported version group are omitted entirely.
    static func normalizedMoves(_ moves: [PokemonMoveDTO]) -> [PokemonMoveOption] {
        moves.compactMap { move in
            let methods = move.version_group_details.compactMap { row -> PokemonMoveLearnMethod? in
                guard row.version_group.name == PokemonDetails.preferredVersionGroup else { return nil }
                return PokemonMoveLearnMethod(method: row.move_learn_method.name,
                                              level: row.level_learned_at)
            }
            guard !methods.isEmpty else { return nil }
            return PokemonMoveOption(name: move.move.name, learnMethods: methods)
        }.sorted { $0.name < $1.name }
    }

    func line(baseSpeciesID: Int) async throws -> EvoLine {
        if let cached = lineCache[baseSpeciesID] { return cached }
        let baseSpecies = try await species(baseSpeciesID)
        // PokéAPI 응답의 URL — 비정상/빈 값이면 force-unwrap 대신 throw(앱은 알 상태 유지).
        guard let chainURL = Self.validatedChainURL(baseSpecies.evolution_chain.url) else {
            throw URLError(.badURL)
        }
        let chainDTO: ChainDTO = try await get(chainURL)
        let tree = node(from: chainDTO.chain)
        let rarity = Rarity.from(captureRate: baseSpecies.capture_rate,
                                 isLegendary: baseSpecies.is_legendary,
                                 isMythical: baseSpecies.is_mythical)
        // Keep all API languages so later app-language additions can reuse persisted names.
        var names: [Int: [String: String]] = [:]
        for id in allIDs(tree) {
            let sp = try await species(id)
            names[id] = PokemonNameLocalization.collect(sp.names)
        }
        let line = EvoLine(baseID: baseSpeciesID, tree: tree, rarity: rarity, names: names)
        lineCache[baseSpeciesID] = line
        return line
    }

    // MARK: base 인덱스 (부화 후보)

    private var baseIndexCache: [BaseSpecies]?
    private var restBuildInFlight = false
    private var restBuildTried = false   // 세션당 1회 (GraphQL 다운 시 REST 인덱스 구축 트리거)
    private static let baseIndexFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("base-index.json")
    }()
    /// REST 구축이 세션 중간에 멈춘 진행분. 완료되면 지운다.
    private static var restProgressFile: URL {
        baseIndexFile.deletingLastPathComponent().appendingPathComponent("base-index-rest-progress.json")
    }
    private struct BaseIndexSnapshot: Codable { let fetchedAt: Date; let entries: [BaseSpecies] }
    private struct GraphQLBaseResponse: Decodable {
        struct DataBox: Decodable { let pokemonspecies: [Row] }
        struct Row: Decodable { let id: Int; let capture_rate: Int }
        let data: DataBox
    }

    /// 1~5세대 base(진화라인 시작점) 전체 — PokéAPI GraphQL 1쿼리.
    /// 우선순위: 메모리 캐시 → 디스크 캐시(30일 TTL) → GraphQL fetch(성공 시 디스크 갱신)
    /// → TTL 지난 디스크라도 있으면 사용(오프라인 폴백). 전부 실패 시 throw(알 유지, 다음 틱 재시도).
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        if let c = baseIndexCache { return c }
        let disk = (try? Data(contentsOf: Self.baseIndexFile))
            .flatMap { try? JSONDecoder().decode(BaseIndexSnapshot.self, from: $0) }
        if let disk, Date().timeIntervalSince(disk.fetchedAt) < 30 * 86400, !disk.entries.isEmpty {
            baseIndexCache = disk.entries
            return disk.entries
        }
        do {
            let entries = try await fetchBaseIndex()
            baseIndexCache = entries
            if let data = try? JSONEncoder().encode(BaseIndexSnapshot(fetchedAt: Date(), entries: entries)) {
                try? data.write(to: Self.baseIndexFile, options: .atomic)
            }
            return entries
        } catch {
            if let disk, !disk.entries.isEmpty {   // 오프라인 — 오래된 인덱스라도 사용
                baseIndexCache = disk.entries
                return disk.entries
            }
            // GraphQL 다운 + 캐시 없음 → REST 로 인덱스를 백그라운드 구축(세션 1회).
            // 이번 부화는 per-hatch REST 폴백(chooseBaseViaREST)이 즉시 처리하고,
            // 구축이 끝나면 디스크 캐시로 남아 이후 선택이 가중·수집반영·오프라인가능으로 복귀한다.
            if !restBuildTried {
                restBuildTried = true
                Task { await self.buildBaseIndexViaREST() }
            }
            AppLog.write("base index (GraphQL) failed, no cache — REST build triggered; per-hatch fallback handles now: \(error)")
            throw error
        }
    }

    /// GraphQL base 인덱스 엔드포인트 장애 시 REST(pokemon-species/{id})로 base 인덱스를 직접 구축·영속.
    /// 한 번 성공하면 base-index.json(30일)으로 남아 이후 선택은 네트워크 없이 가중·수집반영으로 동작 →
    /// 부화가 특정 엔드포인트 생존에 영구히 묶이지 않게 하는 자가치유 캐시. PokéAPI 배려로 소규모 동시성.
    /// 세션마다 처음부터 649 페치를 하지 않는다(run 44143290510): 진행분을 `base-index-rest-progress.json` 에 남기고 다음 세션이
    /// 거기서 잇는다. 네트워크 오류나 종 응답이 하나도 없는 라운드에서 멈추므로 오프라인·PokéAPI 장애는 세션당 한 라운드(6 페치)다.
    func buildBaseIndexViaREST() async {
        guard baseIndexCache == nil, !restBuildInFlight else { return }
        restBuildInFlight = true
        defer { restBuildInFlight = false }
        let file = Self.restProgressFile
        let kept = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(RESTIndexProgress.self, from: $0) }
            .flatMap { Date().timeIntervalSince($0.fetchedAt) < 30 * 86400 ? $0 : nil }
        let start = kept ?? RESTIndexProgress(fetchedAt: Date(), nextID: 1, bases: [])
        AppLog.write(start.nextID > 1
            ? "base index: building via REST from #\(start.nextID) (\(start.bases.count) bases kept from an earlier session)…"
            : "base index: building via REST (GraphQL unavailable)…")
        let (progress, stop) = await Self.runRESTBuild(
            from: start, maxID: PokemonAssets.animatedSpeciesIDs.upperBound, batchSize: 6,
            fetch: { id in try await self.baseSpecies(id: id) },
            save: { p in if let data = try? JSONEncoder().encode(p) { try? data.write(to: file, options: .atomic) } })
        guard stop == .finished else {
            AppLog.write("base index: REST build stopped before #\(progress.nextID) (\(stop == .network ? "network error" : "no species answer")) — "
                         + "\(progress.bases.count) bases kept, the next session goes on from there")
            return
        }
        try? FileManager.default.removeItem(at: file)
        var bases = progress.bases
        // 대부분 실패(네트워크 불안정)면 빈약한 인덱스를 영속하지 않고 다음 세션 재시도.
        guard bases.count >= 150 else {
            AppLog.write("base index: REST build incomplete (\(bases.count)) — not cached, will retry next session")
            return
        }
        bases.sort { $0.id < $1.id }
        baseIndexCache = bases
        if let data = try? JSONEncoder().encode(BaseIndexSnapshot(fetchedAt: Date(), entries: bases)) {
            try? data.write(to: Self.baseIndexFile, options: .atomic)
        }
        AppLog.write("base index: REST build done — \(bases.count) bases persisted (offline-capable now)")
    }

    /// REST 구축의 본체(주입 가능 — `BaseIndexRESTBuildTests`): `progress.nextID` 부터 `batchSize` 씩 동시에 묻는다. 라운드에
    /// 네트워크 오류(URLError)가 하나라도 있거나 라운드 전부가 종 응답이 아니면(5xx 페이지 등, 디코드 실패) 그 라운드 앞에서 멈춘다 —
    /// 실패한 라운드는 건너뛰지 않고 다음 세션이 다시 묻는다. 라운드 안의 일부만 디코드 실패면 그 종만 빠진다(전과 같음).
    /// 라운드가 끝날 때마다 `save` 로 진행분을 넘긴다.
    static func runRESTBuild(from progress: RESTIndexProgress, maxID: Int, batchSize: Int,
                             fetch: @escaping @Sendable (Int) async throws -> BaseSpecies?,
                             save: @Sendable (RESTIndexProgress) -> Void) async -> (RESTIndexProgress, RESTIndexStop) {
        var p = progress
        while p.nextID <= maxID {
            let ids = p.nextID...min(p.nextID + batchSize - 1, maxID)
            let results = await withTaskGroup(of: Result<BaseSpecies?, Error>.self) { group -> [Result<BaseSpecies?, Error>] in
                for id in ids { group.addTask { do { return .success(try await fetch(id)) } catch { return .failure(error) } } }
                var acc: [Result<BaseSpecies?, Error>] = []
                for await r in group { acc.append(r) }
                return acc
            }
            let errors = results.compactMap { r -> Error? in if case .failure(let e) = r { return e }; return nil }
            if errors.contains(where: { $0 is URLError }) { return (p, .network) }
            if errors.count == results.count { return (p, .unanswered) }
            p.bases.append(contentsOf: results.compactMap { r -> BaseSpecies? in if case .success(let b) = r { return b }; return nil })
            p.nextID = ids.upperBound + 1
            save(p)
        }
        return (p, .finished)
    }

    private func fetchBaseIndex() async throws -> [BaseSpecies] {
        // 공식 GraphQL — evolves_from IS NULL(=base) + id ≤ 649(Gen-V 애니메이션 스프라이트 상한)
        guard let url = URL(string: "https://graphql.pokeapi.co/v1beta2") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 메타몽(#132)은 위장 리빌 전용 → 일반 부화 풀에서 제외(_neq).
        let maxID = PokemonAssets.animatedSpeciesIDs.upperBound
        let query = "{ pokemonspecies(where: {evolves_from_species_id: {_is_null: true}, id: {_lte: \(maxID), _neq: \(PokemonOdds.dittoSpeciesID)}}, order_by: {id: asc}) { id capture_rate } }"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await PlatformCompat.oneShotData(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(GraphQLBaseResponse.self, from: data)
        let entries = decoded.data.pokemonspecies.map { BaseSpecies(id: $0.id, captureRate: $0.capture_rate) }
        guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
        return entries
    }

    private func species(_ id: Int) async throws -> SpeciesDTO {
        if let c = speciesCache[id] { return c }
        let dto: SpeciesDTO = try await get(base.appendingPathComponent("pokemon-species/\(id)"))
        speciesCache[id] = dto
        return dto
    }

    /// REST 폴백 — 단일 종 상세(pokemon-species/{id})로 base 여부·capture_rate 판정.
    /// GraphQL base 인덱스가 죽어도 REST(pokeapi.co/api/v2)는 별개 엔드포인트라 동작한다.
    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        guard id != PokemonOdds.dittoSpeciesID else { return nil }   // 메타몽은 위장 리빌 전용 — 일반 부화 제외
        let dto = try await species(id)
        guard dto.evolves_from_species == nil else { return nil }   // 진화 중간체는 부화 후보 아님
        return BaseSpecies(id: id, captureRate: dto.capture_rate)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await PlatformCompat.oneShotData(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func node(from link: ChainLink) -> EvoNode {
        EvoNode(speciesID: Self.id(from: link.species.url ?? ""),
                children: link.evolves_to.map(node(from:)))
    }
    private func allIDs(_ n: EvoNode) -> [Int] { [n.speciesID] + n.children.flatMap(allIDs) }

    static func id(from speciesURL: String) -> Int {
        // ".../pokemon-species/{id}/"
        let parts = speciesURL.split(separator: "/").filter { !$0.isEmpty }
        return Int(parts.last ?? "0") ?? 0
    }

    /// PokéAPI evolution_chain URL 검증(SSRF 가드) — 서버 제어 문자열이므로 https + pokeapi.co 로 고정해
    /// 응답 변조 시 임의 호스트 fetch 를 막는다. 부적합하면 nil(호출부가 throw → 앱은 알 상태 유지).
    static func validatedChainURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "pokeapi.co" else { return nil }
        return url
    }
}

/// REST base 인덱스 구축의 진행분(세션을 넘어 잇는다). `nextID` 앞까지는 다 물었다.
struct RESTIndexProgress: Codable, Equatable, Sendable {
    let fetchedAt: Date
    var nextID: Int
    var bases: [BaseSpecies]
}

/// 한 세션의 REST 구축이 끝난 이유.
enum RESTIndexStop: Equatable, Sendable { case finished, network, unanswered }

// MARK: - DTO (PokéAPI 응답 부분 디코드)

struct SpeciesDTO: Decodable, Sendable {
    let capture_rate: Int
    let is_legendary: Bool
    let is_mythical: Bool
    let names: [NameDTO]
    let evolution_chain: URLRef
    let evolves_from_species: NamedRef?   // nil = 진화라인 시작점(base)
    let gender_rate: Int?
}
struct NameDTO: Decodable, Sendable { let name: String; let language: NamedRef }
struct NamedRef: Decodable, Sendable { let name: String; let url: String? }
struct URLRef: Decodable, Sendable { let url: String }
struct ChainDTO: Decodable, Sendable { let chain: ChainLink }
struct ChainLink: Decodable, Sendable {
    let species: NamedRef
    let evolves_to: [ChainLink]
}

struct PokemonDTO: Decodable, Sendable {
    let name: String
    let height: Int
    let weight: Int
    let base_experience: Int?
    let types: [PokemonTypeDTO]
    let abilities: [PokemonAbilityDTO]
    let stats: [PokemonStatDTO]
    let moves: [PokemonMoveDTO]
}
struct PokemonTypeDTO: Decodable, Sendable { let slot: Int; let type: NamedRef }
struct PokemonAbilityDTO: Decodable, Sendable {
    let is_hidden: Bool
    let slot: Int
    let ability: NamedRef
}
struct PokemonStatDTO: Decodable, Sendable { let base_stat: Int; let stat: NamedRef }
struct PokemonMoveDTO: Decodable, Sendable {
    let move: NamedRef
    let version_group_details: [PokemonMoveVersionDTO]
}
struct PokemonMoveVersionDTO: Decodable, Sendable {
    let level_learned_at: Int
    let move_learn_method: NamedRef
    let version_group: NamedRef
}
