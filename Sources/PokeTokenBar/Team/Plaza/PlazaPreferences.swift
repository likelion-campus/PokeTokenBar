import Foundation

/// 광장 설정(배율, 마지막 위치). 세이브와 무관하게 팀 설정 저장소에 둔다.
@MainActor final class PlazaPreferences {
    private static let zoomKey = "team.plaza.zoom"
    private static let lastTileKey = "team.plaza.lastTile"
    private static let backgroundHiddenKey = "team.plaza.backgroundHidden"
    private static let shortcutsFoldedKey = "team.plaza.shortcutsFolded"
    private static let focusKey = "team.plaza.focus"
    private static let iceBreakKey = "team.plaza.iceBreak"
    private static let takenItemSlotsKey = "team.plaza.takenItemSlots"
    private static let activityKey = "team.plaza.activity"

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

    /// 누군가 주운 것으로 아는 최근 광장 아이템 칸들. 다시 켜도 이미 주운 아이템이 다시 보이지 않게 한다.
    var takenItemSlots: [Int] {
        get { defaults.array(forKey: Self.takenItemSlotsKey) as? [Int] ?? [] }
        set { defaults.set(newValue, forKey: Self.takenItemSlotsKey) }
    }

    /// 왼쪽 위 단축키 안내를 접어 두었다.
    var areShortcutsFolded: Bool {
        get { defaults.bool(forKey: Self.shortcutsFoldedKey) }
        set { defaults.set(newValue, forKey: Self.shortcutsFoldedKey) }
    }

    /// 모닥불 집중 상태. 없으면 nil이고, nil을 넣으면 저장값을 지운다.
    var focus: PlazaFocus? {
        get {
            guard let data = defaults.data(forKey: Self.focusKey) else { return nil }
            return try? JSONDecoder().decode(PlazaFocus.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.focusKey)
                return
            }
            defaults.set(data, forKey: Self.focusKey)
        }
    }

    /// 마지막으로 안 얼음 깨짐. nil을 넣으면 저장값을 지운다.
    var iceBreak: PlazaIceBreak? {
        get {
            guard let data = defaults.data(forKey: Self.iceBreakKey) else { return nil }
            return try? JSONDecoder().decode(PlazaIceBreak.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.iceBreakKey)
                return
            }
            defaults.set(data, forKey: Self.iceBreakKey)
        }
    }

    /// 오늘 광장에서 한 일. 다시 켜도 이어 센다. 날짜가 지났는지는 읽는 쪽이 `rolled(to:)`로 본다.
    var activity: PlazaActivity? {
        get {
            guard let data = defaults.data(forKey: Self.activityKey) else { return nil }
            return try? JSONDecoder().decode(PlazaActivity.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.activityKey)
                return
            }
            defaults.set(data, forKey: Self.activityKey)
        }
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
