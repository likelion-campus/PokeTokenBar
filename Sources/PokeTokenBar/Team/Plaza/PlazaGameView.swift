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
    /// The drawing quiz's board; only a player has one.
    var board: PlazaDrawBoard?

    /// The mark of one member; nil when they do not play.
    func mark(of id: String) -> PlazaGameMark? {
        if id == holder { return .holder }
        return alive.contains(id) ? .alive : out.contains(id) ? .out : nil
    }

    /// `name`: a member's nickname. `joinedCount`: how many said yes, the host included. `canPlay`: I am not an egg.
    /// `flash`: an explosion or the result, shown as the title until it runs out. Who gets the next bomb stays hidden
    /// until it is live, so nobody gets a head start on the holder.
    /// `drawNote`: why the drawer's word was refused, shown as the hint while the word field is open.
    static func make(engine: PlazaGameEngine, now: Date, joinedCount: Int, canPlay: Bool, flash: Title?, drawNote: String? = nil,
                     name: (String) -> String?) -> PlazaGameView {
        var view = PlazaGameView()
        guard let s = engine.state, let phase = engine.phase(now: now) else { return view }
        let l = L(.ko), t = now.timeIntervalSince1970, me = engine.me
        let kind = PlazaGameKind(rawValue: s.kind)
        let game = kind.map(l.plazaGameName) ?? l.plazaGameUnknownName
        let isPlayer = engine.isPlayer
        func nick(_ id: String) -> String { name(id) ?? l.plazaGroupPhotoSomeone }
        if kind == .draw, phase != .recruiting {
            return drawView(engine: engine, state: s, phase: phase, now: now, flash: flash, drawNote: drawNote, name: nick)
        }
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
            let status = kind == .draw ? l.plazaDrawRecruiting(players: joinedCount, seconds: left) : l.plazaGameRecruiting(players: joinedCount, seconds: left)
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
                let full = kind == .draw && joinedCount >= PlazaDraw.maxPlayers
                if full { card.lines.append(l.plazaDrawFull) }
                card.buttons = [Button(label: l.plazaGameButtonJoin, action: "join", isEnabled: !full), Button(label: l.plazaGameButtonDecline, action: "decline")]
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

extension PlazaGameView {
    /// A running or ended drawing quiz. A player gets the board, the hint line and the big title; a teammate who is not playing gets the name line
    /// only, and at the end everyone in the plaza gets the ranking card. The rings are the bomb game's: every player is in, nobody holds anything.
    fileprivate static func drawView(engine: PlazaGameEngine, state s: PlazaGameState, phase: PlazaGame.Phase, now: Date, flash: Title?,
                                     drawNote: String?, name nick: (String) -> String) -> PlazaGameView {
        var view = PlazaGameView()
        let l = L(.ko), me = engine.me
        guard let d = s.draw else { return view }   // a copy an old app passed on: nothing to show
        if phase == .ended {
            view.card = rankingCard(PlazaDraw.ranking(s), name: nick)
            view.title = flash
            return view
        }
        guard let drawPhase = engine.drawPhase(now: now) else { return view }
        view.alive = s.players
        view.status = l.plazaDrawStatus(scores: PlazaDraw.ranking(s).map { (nick($0.id), $0.score) }, watching: !engine.isPlayer)
        guard engine.isPlayer, let who = engine.drawer else { return view }
        let mine = who == me
        func seconds(_ t: TimeInterval) -> Int { max(0, Int(t.rounded(.up))) }
        let head = l.plazaDrawHead(turn: min(d.turn + 1, d.order.count), of: d.order.count, drawer: mine ? nil : nick(who))
        func board(_ left: TimeInterval, cover: String?, foot: PlazaDrawBoard.Foot, canDraw: Bool = false) -> PlazaDrawBoard {
            PlazaDrawBoard(head: head, time: l.plazaDrawTime(seconds: seconds(left)), cover: cover, foot: foot, canDraw: canDraw)
        }
        func next(_ left: TimeInterval) -> String { l.plazaDrawNext(nickname: mine ? nil : nick(who), seconds: seconds(left)) }
        switch drawPhase {
        case .countdown(let left):
            view.title = Title(text: "\(max(1, seconds(left)))", tone: .count)
            view.board = board(left, cover: next(left), foot: .lines([]))
        case .reveal(let left):
            view.board = board(left, cover: next(left), foot: .lines(d.last.map { resultLines($0, name: nick) } ?? []))
        case .entry(let left):
            view.board = board(left, cover: mine ? l.plazaDrawMyEntry(seconds: seconds(left)) : l.plazaDrawOtherEntry(nickname: nick(who), seconds: seconds(left)),
                               foot: .lines([]))
            if mine { view.hint = drawNote }
        case .drawing(let left):
            if mine, let word = engine.myWord {
                view.board = board(left, cover: nil, foot: .tools(word: word), canDraw: true)
                view.hint = l.plazaDrawMyDrawing(seconds: seconds(left))
            } else if !mine {
                var hints = [d.letters.map(l.plazaDrawHintLetters)
                    ?? l.plazaDrawHintLater(seconds: Int(PlazaDraw.drawSeconds - PlazaDraw.lettersHintSeconds))]
                if let initials = d.initials { hints.append(l.plazaDrawHintInitials(initials)) }
                view.board = board(left, cover: nil, foot: .lines(hints))
                view.hint = l.plazaDrawOtherDrawing(nickname: nick(who), seconds: seconds(left))
            }
        case .over:
            break
        }
        if let flash { view.title = flash }
        return view
    }

    /// What the last turn came to, as the two lines under the empty canvas between turns.
    static func resultLines(_ r: PlazaDrawState.Result, name nick: (String) -> String) -> [String] {
        let l = L(.ko)
        let points = r.solver.map {
            l.plazaDrawResultPoints(solver: nick($0), solverPoints: PlazaDraw.guessPoints, drawer: nick(r.drawer), drawerPoints: PlazaDraw.drawerPoints)
        }
        switch (r.solver, r.word) {
        case (let solver?, let word?): return [l.plazaDrawResultSolved(word: word, solver: nick(solver)), points ?? ""]
        case (_, let word?): return [l.plazaDrawResultTimeout(word: word), l.plazaDrawResultNoPoints]
        case (_?, nil): return [l.plazaDrawResultUnknown, points ?? ""]
        case (nil, nil): return [l.plazaDrawResultUnknown, l.plazaDrawResultNoPoints]
        }
    }

    /// The finished quiz: one line per player, best first; players on the same score share the place and are marked as tied.
    static func rankingCard(_ ranking: [(id: String, score: Int)], name nick: (String) -> String) -> Card {
        let l = L(.ko)
        var rank = 1
        let lines = ranking.enumerated().map { i, r -> String in
            if i > 0, r.score != ranking[i - 1].score { rank = i + 1 }
            return l.plazaDrawRankLine(rank: rank, name: nick(r.id), score: r.score, tied: ranking.filter { $0.score == r.score }.count > 1)
        }
        return Card(title: l.plazaDrawRankingTitle, lines: lines)
    }
}

/// What the minigame panels follow.
@MainActor @Observable
final class PlazaGameModel {
    var card: PlazaGameView.Card?
    var title: PlazaGameView.Title?
}
