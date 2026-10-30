import Foundation
import CryptoKit
import Observation

@MainActor @Observable
final class TeamSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "team.enabled") } }
    var code: TeamCode? {
        didSet {
            if let code { defaults.set(code.normalized, forKey: "team.code") }
            else { defaults.removeObject(forKey: "team.code") }
        }
    }
    var nickname: String { didSet { defaults.set(nickname, forKey: "team.nickname") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "team.notifications") } }
    let memberID: String

    init(defaults: UserDefaults = TeamSettings.defaultStore()) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "team.enabled") as? Bool ?? false
        code = defaults.string(forKey: "team.code").flatMap { TeamCode(parsing: $0) }
        nickname = defaults.string(forKey: "team.nickname") ?? ""
        notificationsEnabled = defaults.object(forKey: "team.notifications") as? Bool ?? true
        if let id = defaults.string(forKey: "team.memberID"), !id.isEmpty {
            memberID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "team.memberID")
            memberID = id
        }
    }

    var isReady: Bool { isEnabled && code != nil && Self.validNickname(nickname) != nil }

    /// 공백 정리 후 1~12 Character, 개행 없음. 아니면 nil.
    static func validNickname(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard (1...12).contains(t.count), !t.contains(where: \.isNewline) else { return nil }
        return t
    }

    /// 상태 폴더가 기본 위치면 nil(=`.standard`), 아니면 경로 해시 suite 이름(한 Mac에서 두 인스턴스 테스트용).
    static func suiteName(for directory: URL, defaultDirectory: URL) -> String? {
        let path = directory.standardizedFileURL.path
        guard path != defaultDirectory.standardizedFileURL.path else { return nil }
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "ptb.team." + hash
    }

    static func defaultStore() -> UserDefaults {
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar", isDirectory: true)
        guard let name = suiteName(for: AppStatePaths.directory(), defaultDirectory: defaultDir) else { return .standard }
        return UserDefaults(suiteName: name) ?? .standard
    }

    func leaveTeam() {
        code = nil
        isEnabled = false
    }
}
