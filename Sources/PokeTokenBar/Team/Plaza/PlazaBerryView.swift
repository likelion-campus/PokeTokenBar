import Foundation

extension PlazaBerryBoard {
    /// The table as `engine` knows it, for its own player; nil unless I am a player of a locked berry game with its payload.
    @MainActor static func make(engine: PlazaGameEngine, now: Date, uptime: TimeInterval,
                                seat info: (String) -> (name: String, color: PlazaColor, mon: TeamMonSummary)) -> PlazaBerryBoard? {
        let me = engine.me
        guard engine.isPlayer, let s = engine.state, let b = s.berry, let phase = engine.berryPhase(now: now),
              let mine = s.players.firstIndex(of: me) else { return nil }
        let l = L(.ko)
        let n = s.players.count
        let order = (0..<n).map { (mine + $0) % n }
        let decks = PlazaBerry.decks(seed: s.seed, seats: n)
        let top = PlazaBerry.table(s)
        let playing = engine.berryPlaying
        func shown(_ id: String) -> String? { id == me ? nil : info(id).name }
        func index(of seat: Int) -> Int { (seat - mine + n) % n }

        let seats = order.map { k -> Seat in
            let id = s.players[k], who = info(id)
            let pile = PlazaBerry.under(b, seat: k)
            return Seat(id: id, name: who.name, nameColor: who.color, mon: who.mon, score: b.scores[k],
                        deckLeft: PlazaBerry.deckLeft(b, decks: decks, seat: k), top: top.indices.contains(k) ? top[k] : nil,
                        under: top.indices.contains(k) && top[k] != nil ? max(0, pile - 1) : 0, isPlaying: playing.contains(id))
        }

        let center: Center
        switch phase {
        case .countdown(let left):
            center = .countdown(max(1, Int(left.rounded(.up))))
        case .playing:
            var event: String?
            if let v = b.last, s.players.indices.contains(v.seat) {
                let name = shown(s.players[v.seat])
                event = v.right ? l.plazaBerryRang(nickname: name, ms: v.ms) : l.plazaBerryMissed(nickname: name)
            }
            center = .playing(event: event)
        case .over:
            let ranking = PlazaBerry.ranking(s)
            var lines: [String] = []
            if let winner = s.winner {
                lines.append(l.plazaBerryWinner(nickname: shown(winner)))
            } else {
                let best = ranking.first?.score ?? 0
                lines.append(l.plazaBerryTie(names: ranking.filter { $0.score == best }.map { info($0.id).name }))
            }
            for (i, r) in ranking.enumerated() {
                let place = (ranking.firstIndex { $0.score == r.score } ?? i) + 1
                lines.append(l.plazaBerryRank(place: place, nickname: info(r.id).name, score: r.score, tied: ranking.filter { $0.score == r.score }.count > 1))
            }
            lines.append(l.plazaBerryCloseHint)
            center = .result(lines: lines)
        }

        var ring: Ring?
        if let v = b.last, v.right, v.clear == b.clears.count - 1, let clearFlip = b.clears.last, s.players.indices.contains(v.seat) {
            let swept = PlazaBerry.table(b, decks: decks, flip: clearFlip, clear: v.clear)
            let atBell = PlazaBerry.table(b, decks: decks, flip: v.flip, clear: v.clear)
            let fives = PlazaBerry.fives(atBell)
            let five = Set(order.indices.filter { i in atBell[order[i]].map { fives.contains($0.berry) } ?? false })
            ring = Ring(clear: v.clear, seat: index(of: v.seat), swept: order.map { swept[$0] }, five: five)
        }

        return PlazaBerryBoard(seats: seats, center: center, flip: b.flips.count, flippedSeat: b.flips.last.map(index(of:)), ring: ring,
                               wrong: engine.berryLocked(uptime: uptime))
    }
}
