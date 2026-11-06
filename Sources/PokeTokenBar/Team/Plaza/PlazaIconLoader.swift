import AppKit

/// PokéAPI 7세대 박스 아이콘을 받아 스프라이트 캐시 폴더에 `icon-<id>.png`로 둔다.
enum PlazaIconLoader {
    static func url(speciesID: Int) -> URL {
        URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-vii/icons/\(speciesID).png")!
    }

    /// 이번 실행에서 그린 아이콘. 목록 페이지를 넘겨도 다시 읽지 않고 바로 그린다.
    @MainActor private static var memory: [Int: NSImage] = [:]

    @MainActor
    static func cachedIcon(speciesID: Int) -> NSImage? { memory[speciesID] }

    /// 메모리나 캐시에 있으면 그것을, 없으면 받아서 캐시한다. 실패하면 nil(화면은 빈 자리표시를 그린다).
    @MainActor
    static func icon(speciesID: Int, load: (Int) async -> Data? = iconData) async -> NSImage? {
        if let kept = memory[speciesID] { return kept }
        guard let data = await load(speciesID), let image = NSImage(data: data) else { return nil }
        memory[speciesID] = image
        return image
    }

    /// 파일·네트워크는 메인 액터 밖에서 처리하고, 격리 경계는 `NSImage` 대신 `Data`로 넘는다.
    private static func iconData(speciesID: Int) async -> Data? {
        let file = SpriteStore.shared.directory.appendingPathComponent("icon-\(speciesID).png")
        if let cached = try? Data(contentsOf: file), NSImage(data: cached) != nil { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url(speciesID: speciesID)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              NSImage(data: data) != nil else { return nil }
        try? data.write(to: file, options: .atomic)
        return data
    }
}
