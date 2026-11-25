import Foundation
import Observation

/// 미니게임 키. M: 메뉴를 열거나, 판을 연 사람이면 바로 시작. Y: 참가. N: 안 함(빠지기, 취소, 닫기).
enum PlazaGameKey: Equatable, Sendable { case menu, yes, no }

/// M으로 여는 미니게임 메뉴. 고를 수 있는 줄은 게임마다 하나이고, 열 수 없을 때는 줄 대신 까닭 한 줄이 보인다.
struct PlazaGameMenu: Equatable {
    var kinds: [PlazaGameKind] = PlazaGameKind.offered
    var selection = 0
    /// 지금 판을 열 수 없는 까닭. nil이면 열 수 있다.
    var blocked: String?

    mutating func move(by step: Int) {
        guard !kinds.isEmpty else { return }
        selection = ((selection + step) % kinds.count + kinds.count) % kinds.count
    }
}

/// How a character in a running game is marked, on the ground under it and on the minimap: still in, holding the live
/// bomb, or out. A character with no mark is not playing.
enum PlazaGameMark: Equatable, Sendable { case alive, holder, out }

/// What the plaza draws for the minigame right now: derived from the engine on every tick, never stored.
struct PlazaGameView: Equatable {
    struct Button: Equatable {
        let label: String
        /// "join", "decline" or "start": what `PlazaWindowController.gameAction` does.
        let action: String
        var isEnabled = true
    }

    /// The invitation under the pills: who opened which game, the rules, how many are in, and the answer buttons.
    struct Card: Equatable {
        var title: String
        var lines: [String]
        var buttons: [Button] = []
    }

    enum Tone: Equatable { case count, go, out, win }

    /// The big line in the middle of the window.
    struct Title: Equatable {
        var text: String
        var tone: Tone
    }

    var card: Card?
    var title: Title?
    /// The top hint line while I play; it wins over the plaza's other hints.
    var hint: String?
    /// Who has the bomb over their head.
    var holder: String?
    var urgent = false
    /// Everyone in the locked game, for players and watchers alike: who is still in and who is out, each in the game's
    /// order. Empty before the players are locked in and after the game ends.
    var alive: [String] = []
    var out: [String] = []
    /// The line that names them under the hint, as long as the game runs.
    var status: String?

    /// The mark of one member; nil when they do not play.
    func mark(of id: String) -> PlazaGameMark? {
        if id == holder { return .holder }
        return alive.contains(id) ? .alive : out.contains(id) ? .out : nil
    }

    /// `name`: a member's nickname. `joinedCount`: how many said yes, the host included. `canPlay`: I am not an egg.
    /// `flash`: an explosion or the result, shown as the title until it runs out. Who gets the next bomb stays hidden
    /// until it is live, so nobody gets a head start on the holder.
    static func make(engine: PlazaGameEngine, now: Date, joinedCount: Int, canPlay: Bool, flash: Title?,
                     name: (String) -> String?) -> PlazaGameView {
        var view = PlazaGameView()
        guard let s = engine.state, let phase = engine.phase(now: now) else { return view }
        let l = L(.ko), t = now.timeIntervalSince1970, me = engine.me
        let kind = PlazaGameKind(rawValue: s.kind)
        let game = kind.map(l.plazaGameName) ?? l.plazaGameUnknownName
        let isPlayer = engine.isPlayer
        func nick(_ id: String) -> String { name(id) ?? l.plazaGroupPhotoSomeone }
        switch phase {
        case .recruiting:
            guard engine.declined != s.id else { break }
            let left = max(0, Int((s.opensAt + PlazaGame.recruitSeconds - t).rounded(.up)))
            var card = Card(title: l.plazaGameCardTitle(host: s.host == me ? nil : nick(s.host), game: game), lines: [])
            guard let kind else {
                card.lines = [l.plazaGameUpdateNote]
                card.buttons = [Button(label: l.plazaGameButtonClose, action: "decline")]
                view.card = card
                break
            }
            card.lines = l.plazaGameRules(kind)
            let status = l.plazaGameRecruiting(players: joinedCount, seconds: left)
            if s.host == me {
                card.lines.append(joinedCount < PlazaGame.minPlayers ? l.plazaGameNeedsTwo(seconds: left) : status)
                card.buttons = [Button(label: l.plazaGameButtonStart, action: "start", isEnabled: joinedCount >= PlazaGame.minPlayers),
                                Button(label: l.plazaGameButtonCancel, action: "decline")]
            } else if !canPlay {
                card.lines.append(l.plazaGameEggNote)
                card.buttons = [Button(label: l.plazaGameButtonClose, action: "decline")]
            } else if engine.joined == s.id {
                card.lines.append("\(l.plazaGameJoined) \(status)")
                card.buttons = [Button(label: l.plazaGameButtonLeave, action: "decline")]
            } else {
                card.lines.append(status)
                card.buttons = [Button(label: l.plazaGameButtonJoin, action: "join"), Button(label: l.plazaGameButtonDecline, action: "decline")]
            }
            view.card = card
        case .countdown:
            view.alive = s.players
            view.status = l.plazaGameStatus(alive: s.players.map(nick), out: [], holder: nil)
            guard isPlayer, let starts = s.startsAt else { break }
            view.title = Title(text: "\(max(1, Int((starts - t).rounded(.up))))", tone: .count)
            if let kind {
                view.card = Card(title: game, lines: l.plazaGameRules(kind) + [l.plazaGamePlayers(s.players.map(nick))])
            }
            view.hint = l.plazaGameScatterHint
        case .playing:
            guard let b = s.bomb else { break }
            let live = t >= b.roundStartsAt
            view.holder = live ? b.holder : nil
            if live, let explodes = PlazaBomb.explodesAt(s) { view.urgent = explodes - t <= PlazaBomb.urgentSeconds }
            let alive = PlazaBomb.alive(s)
            view.alive = alive
            view.out = b.out.filter(s.players.contains)
            view.status = l.plazaGameStatus(alive: alive.map(nick), out: view.out.map(nick), holder: view.holder.map(nick))
            guard isPlayer else { break }
            if live, t < b.roundStartsAt + 1 { view.title = Title(text: b.round == 1 ? l.plazaGameGo : l.plazaGameNextBomb, tone: .go) }
            if !alive.contains(me) {
                view.hint = l.plazaGameOutHint(left: alive.count)
            } else if !live {
                view.hint = l.plazaGameScatterHint
            } else if b.holder == me {
                if let from = b.from, let at = b.passedAt, t - at < PlazaBomb.returnImmunity {
                    view.hint = l.plazaGameNoReturnHint(nickname: nick(from))
                } else {
                    view.hint = l.plazaGameHoldHint
                }
            } else {
                view.hint = l.plazaGameRunHint(nickname: nick(b.holder))
            }
        case .ended:
            break
        }
        if let flash { view.title = flash }
        return view
    }
}

/// What the minigame panels follow.
@MainActor @Observable
final class PlazaGameModel {
    var card: PlazaGameView.Card?
    var title: PlazaGameView.Title?
}
