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
            if let code { remember(code) }
        }
    }
    /// 들어갔던 팀. 다시 코드를 넣지 않고 팀을 바꿀 수 있다. 코드처럼 이 Mac에만 저장한다.
    private(set) var savedTeams: [SavedTeam] {
        didSet { defaults.set(try? JSONEncoder().encode(savedTeams), forKey: "team.saved") }
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
        savedTeams = defaults.data(forKey: "team.saved")
            .flatMap { try? JSONDecoder().decode([SavedTeam].self, from: $0) }?
            .filter { TeamCode(parsing: $0.code) != nil } ?? []
        if let id = defaults.string(forKey: "team.memberID"), !id.isEmpty {
            memberID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "team.memberID")
            memberID = id
        }
        // v2.5.602 and earlier kept only the current code.
        if let code { remember(code) }
    }

    struct SavedTeam: Codable, Equatable, Identifiable {
        var code: String
        var name: String
        var id: String { code }
    }

    /// The saved entry of the team I'm in, if any.
    var currentTeam: SavedTeam? { code.flatMap { c in savedTeams.first { $0.code == c.normalized } } }

    private func remember(_ code: TeamCode) {
        guard !savedTeams.contains(where: { $0.code == code.normalized }) else { return }
        savedTeams.append(SavedTeam(code: code.normalized, name: L(.ko).teamDefaultName(savedTeams.count + 1)))
    }

    /// Moves to a saved team. The news board starts over, as when joining any other team.
    func switchTo(_ team: SavedTeam) {
        guard let parsed = TeamCode(parsing: team.code) else { return }
        code = parsed
    }

    /// Leaves the current team for now so another can be made or joined. It stays saved.
    func stepOut() {
        code = nil
    }

    /// Names the current team with the nickname rules. An invalid name changes nothing.
    @discardableResult
    func renameCurrentTeam(_ raw: String) -> Bool {
        guard let name = Self.validNickname(raw), let current = currentTeam,
              let i = savedTeams.firstIndex(of: current) else { return false }
        if savedTeams[i].name != name { savedTeams[i].name = name }
        return true
    }

    var isReady: Bool { isEnabled && code != nil && Self.validNickname(nickname) != nil }

    /// 공백 정리 후 1~12 Character, 개행 없음, UTF-8 320바이트 이하. 아니면 nil.
    /// ZWJ 이모지 사슬은 길이와 상관없이 Character 하나라서 Character 수는 크기 상한이 아니다.
    static func validNickname(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard (1...12).contains(t.count), t.utf8.count <= 320, !t.contains(where: \.isNewline) else { return nil }
        return t
    }

    /// Stores a nickname only when it is valid, so an edit in progress never takes the team down.
    @discardableResult
    func commitNickname(_ raw: String) -> Bool {
        guard let valid = Self.validNickname(raw) else { return false }
        if nickname != valid { nickname = valid }
        return true
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

    /// Leaves the team for good: it is also removed from the saved teams.
    func leaveTeam() {
        if let current = code?.normalized { savedTeams.removeAll { $0.code == current } }
        code = nil
        isEnabled = false
    }
}
