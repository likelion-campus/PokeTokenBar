import Foundation

/// 광장 설정(배율, 마지막 위치). 세이브와 무관하게 팀 설정 저장소에 둔다.
@MainActor final class PlazaPreferences {
    private static let zoomKey = "team.plaza.zoom"
    private static let lastTileKey = "team.plaza.lastTile"
    private static let backgroundHiddenKey = "team.plaza.backgroundHidden"
    private static let shortcutsFoldedKey = "team.plaza.shortcutsFolded"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = TeamSettings.defaultStore()) {
        self.defaults = defaults
    }

    var zoom: Int {
        get {
            guard let stored = defaults.object(forKey: Self.zoomKey) as? Int else { return PlazaCamera.defaultZoom }
            return PlazaCamera.clampedZoom(stored)
        }
        set { defaults.set(PlazaCamera.clampedZoom(newValue), forKey: Self.zoomKey) }
    }

    /// 지도와 바탕을 숨기고 캐릭터만 보이게 한다. 창 뒤의 작업 화면이 비친다.
    var isBackgroundHidden: Bool {
        get { defaults.bool(forKey: Self.backgroundHiddenKey) }
        set { defaults.set(newValue, forKey: Self.backgroundHiddenKey) }
    }

    /// 왼쪽 위 단축키 안내를 접어 두었다.
    var areShortcutsFolded: Bool {
        get { defaults.bool(forKey: Self.shortcutsFoldedKey) }
        set { defaults.set(newValue, forKey: Self.shortcutsFoldedKey) }
    }

    /// 저장된 칸이 없거나 지도 밖이거나 못 가는 칸이면 시작 칸.
    func lastTile(validIn map: PlazaMap) -> TilePoint {
        guard let data = defaults.data(forKey: Self.lastTileKey),
              let tile = try? JSONDecoder().decode(TilePoint.self, from: data),
              map.isWalkable(tile) else { return map.spawn }
        return tile
    }

    func saveLastTile(_ p: TilePoint) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        defaults.set(data, forKey: Self.lastTileKey)
    }
}
