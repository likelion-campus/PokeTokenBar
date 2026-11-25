import XCTest
@testable import PokeTokenBar

/// The drawing quiz's rules: the text rules, the order, the transitions and the bounds on a received payload.
final class PlazaDrawTests: XCTestCase {
    // MARK: - Text rules

    /// A Hangul syllable written as conjoining jamo (what a decomposed keyboard or file gives).
    private func decomposed(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0xAC00...0xD7A3).contains(u.value) {
                let i = Int(u.value) - 0xAC00
                out.append(Unicode.Scalar(UInt32(0x1100 + i / 588))!)
                out.append(Unicode.Scalar(UInt32(0x1161 + (i % 588) / 28))!)
                if i % 28 != 0 { out.append(Unicode.Scalar(UInt32(0x11A7 + i % 28))!) }
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    func testTheWordLimitsStayInStepWithTheChatInput() {
        XCTAssertEqual(PlazaChatInputPurpose.quizWord.maxCharacters, PlazaDraw.maxWordCharacters)
    }

    func testAWordIsOneToTwelveLettersDigitsAndSpaces() {
        XCTAssertEqual(PlazaDraw.word(" 사과 "), "사과")
        XCTAssertEqual(PlazaDraw.word("ice  cream"), "ice cream")
        XCTAssertEqual(PlazaDraw.word("사과2개"), "사과2개")
        XCTAssertEqual(PlazaDraw.word("123456789012"), "123456789012")
        XCTAssertNil(PlazaDraw.word(""))
        XCTAssertNil(PlazaDraw.word("   "))
        XCTAssertNil(PlazaDraw.word("1234567890123"), "13 characters")
        XCTAssertNil(PlazaDraw.word("사과!"))
        XCTAssertNil(PlazaDraw.word("🍎"))
        XCTAssertNil(PlazaDraw.word("사\n과"))
        XCTAssertNil(PlazaDraw.word("사과\n"))
        let marks = String(repeating: "\u{0301}", count: 8)
        let heavy = String(repeating: "e" + marks, count: 12)
        XCTAssertEqual(heavy.count, 12)
        XCTAssertGreaterThan(heavy.utf8.count, PlazaDraw.maxWordBytes)
        XCTAssertNil(PlazaDraw.word(heavy), "12 characters, but more than 64 bytes")
        XCTAssertNotNil(PlazaDraw.word(String(repeating: "사", count: 12)), "12 syllables are 36 bytes")
    }

    func testAnAnswerMatchesWhateverItsSpacingCaseOrComposition() {
        let word = "아이스 크림"
        for line in ["아이스크림", " 아이스  크림!", "아이스크림~~", "\"아이스크림\"", "‘아이스크림’", "아이스크림…"] {
            XCTAssertTrue(PlazaDraw.matches(line, word: word), line)
        }
        XCTAssertTrue(PlazaDraw.matches(decomposed("아이스크림"), word: word), "decomposed jamo")
        XCTAssertTrue(PlazaDraw.matches("아이스크림", word: decomposed(word)))
        XCTAssertTrue(PlazaDraw.matches("apple", word: "Apple"))
        XCTAssertTrue(PlazaDraw.matches("APPLE.", word: "Apple"))
        XCTAssertFalse(PlazaDraw.matches("사과인가", word: "사과"))
        XCTAssertFalse(PlazaDraw.matches("사과ㅋㅋ", word: "사과"))
        XCTAssertFalse(PlazaDraw.matches("사 과 요", word: "사과"))
        XCTAssertFalse(PlazaDraw.matches("", word: "사과"))
        XCTAssertFalse(PlazaDraw.matches("!!", word: "사과"))
    }

    func testTheDrawersOwnLineIsBlockedOnlyWhenItHoldsTheWord() {
        XCTAssertTrue(PlazaDraw.contains("힌트: 사 과!", word: "사과"))
        XCTAssertTrue(PlazaDraw.contains(decomposed("이건 사과야"), word: "사과"))
        XCTAssertFalse(PlazaDraw.contains("과일이야", word: "사과"))
        XCTAssertFalse(PlazaDraw.contains("", word: "사과"))
    }

    func testHintsCountLettersAndGiveInitials() {
        XCTAssertEqual(PlazaDraw.letters("아이스 크림"), 5)
        XCTAssertEqual(PlazaDraw.initials("사과"), "ㅅㄱ")
        XCTAssertEqual(PlazaDraw.initials(decomposed("사과")), "ㅅㄱ")
        XCTAssertEqual(PlazaDraw.initials("꽃 2송이"), "ㄲ○ㅅㅇ")
        XCTAssertEqual(PlazaDraw.initials("TV"), "○○")
        let none = PlazaDraw.hints(elapsed: 29.9, word: "사과")
        XCTAssertNil(none.letters); XCTAssertNil(none.initials)
        let first = PlazaDraw.hints(elapsed: 30, word: "사과")
        XCTAssertEqual(first.letters, 2); XCTAssertNil(first.initials)
        let second = PlazaDraw.hints(elapsed: 45, word: "사과")
        XCTAssertEqual(second.letters, 2); XCTAssertEqual(second.initials, "ㅅㄱ")
    }

    // MARK: - Order

    func testTheOrderIsEveryPlayerOnceOrTwiceAndTheSameForOneSeed() {
        let three = PlazaDraw.order(players: ["a", "b", "c"], seed: 5)
        XCTAssertEqual(three.count, 6)
        XCTAssertEqual(Array(three[3...]), Array(three[..<3]))
        XCTAssertEqual(Set(three), ["a", "b", "c"])
        XCTAssertEqual(PlazaDraw.order(players: ["a", "b", "c", "d"], seed: 5).count, 8)
        let five = PlazaDraw.order(players: ["a", "b", "c", "d", "e"], seed: 5)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(Set(five).count, 5)
        let eight = PlazaDraw.order(players: ["a", "b", "c", "d", "e", "f", "g", "h"], seed: 5)
        XCTAssertEqual(eight.count, 8)
        XCTAssertEqual(Set(eight).count, 8)
        XCTAssertEqual(PlazaDraw.order(players: ["a", "b", "c", "d", "e"], seed: 5), five)
        XCTAssertEqual(PlazaDraw.order(players: ["c", "a", "b", "e", "d"], seed: 5), five, "the player list's order does not matter")
        let orders = Set((1...20).map { PlazaDraw.order(players: ["a", "b", "c", "d", "e"], seed: UInt64($0)) })
        XCTAssertGreaterThan(orders.count, 1)
    }

    // MARK: - Transitions

    private func game(order: [String] = ["a", "b", "c"], turn: Int = 0, players: [String] = ["a", "b", "c"],
                      scores: [String: Int] = [:]) -> PlazaGameState {
        var s = PlazaGameState(id: "a@1", kind: "draw", host: "a", opensAt: 1_800_000_000)
        s.startsAt = 1_800_000_030
        s.players = players
        s.draw = PlazaDrawState(order: order, turn: turn, step: 0, scores: scores)
        return s
    }

    func testOnlyTheDrawerOpensAndSetsAndEachStepCounts() {
        let s = game(order: ["b", "a", "c"])
        XCTAssertNil(PlazaDraw.opened(s, by: "a", at: 100))
        XCTAssertNil(PlazaDraw.wordSet(s, by: "b", at: 100), "no word before the field was opened")
        XCTAssertNil(PlazaDraw.hinted(s, by: "b", letters: 2, initials: nil))
        let opened = PlazaDraw.opened(s, by: "b", at: 100)
        XCTAssertEqual(opened?.draw?.entryAt, 100)
        XCTAssertEqual(opened?.draw?.step, 1)
        XCTAssertNil(PlazaDraw.opened(opened!, by: "b", at: 101), "opened once")
        XCTAssertNil(PlazaDraw.wordSet(opened!, by: "a", at: 105))
        let set = PlazaDraw.wordSet(opened!, by: "b", at: 105)
        XCTAssertEqual(set?.draw?.drawAt, 105)
        XCTAssertEqual(set?.draw?.step, 2)
        XCTAssertNil(PlazaDraw.wordSet(set!, by: "b", at: 106), "set once")
        XCTAssertNil(PlazaDraw.hinted(set!, by: "a", letters: 2, initials: nil))
        let hinted = PlazaDraw.hinted(set!, by: "b", letters: 2, initials: nil)
        XCTAssertEqual(hinted?.draw?.letters, 2)
        XCTAssertEqual(hinted?.draw?.step, 3)
        let both = PlazaDraw.hinted(hinted!, by: "b", letters: 2, initials: "ㅅㄱ")
        XCTAssertEqual(both?.draw?.initials, "ㅅㄱ")
        XCTAssertEqual(both?.draw?.step, 4)
        XCTAssertNil(PlazaDraw.hinted(both!, by: "b", letters: 2, initials: "ㅅㄱ"), "nothing new")
    }

    func testEndingATurnScoresAndMovesOn() {
        var s = game(order: ["b", "a", "c"])
        s = PlazaDraw.wordSet(PlazaDraw.opened(s, by: "b", at: 100)!, by: "b", at: 105)!
        s = PlazaDraw.hinted(s, by: "b", letters: 2, initials: "ㅅㄱ")!
        let step = s.draw!.step
        let next = PlazaDraw.ended(s, word: "사과", solver: "c", playing: ["a", "b", "c"], at: 120)
        let d = next.draw!
        XCTAssertEqual(d.scores["c"], PlazaDraw.guessPoints)
        XCTAssertEqual(d.scores["b"], PlazaDraw.drawerPoints)
        XCTAssertEqual(d.last, PlazaDrawState.Result(turn: 0, drawer: "b", word: "사과", solver: "c"))
        XCTAssertEqual(d.turn, 1)
        XCTAssertNil(d.entryAt); XCTAssertNil(d.drawAt); XCTAssertNil(d.letters); XCTAssertNil(d.initials)
        XCTAssertEqual(d.step, step + 1)
        XCTAssertNil(next.endedAt)

        let timedOut = PlazaDraw.ended(s, word: "사과", solver: nil, playing: ["a", "b", "c"], at: 120).draw!
        XCTAssertTrue(timedOut.scores.values.allSatisfy { $0 == 0 })
        XCTAssertNil(timedOut.last?.solver)
        let stranger = PlazaDraw.ended(s, word: "사과", solver: "zed", playing: ["a", "b", "c"], at: 120).draw!
        XCTAssertNil(stranger.scores["zed"])
        XCTAssertNil(stranger.scores["b"], "a solver who is no player scores nobody")
    }

    func testADrawerWhoIsNotPlayingIsSkippedOnceNotRemoved() {
        let order = ["a", "b", "c", "a", "b", "c"]
        let s = game(order: order)
        let skipped = PlazaDraw.ended(s, word: nil, solver: nil, playing: ["a", "c"], at: 100)
        XCTAssertEqual(skipped.draw?.turn, 2)
        XCTAssertEqual(skipped.draw?.order, order, "the order is kept whole")
        let afterC = PlazaDraw.ended(skipped, word: nil, solver: nil, playing: ["a", "b", "c"], at: 110)
        XCTAssertEqual(afterC.draw?.turn, 3)
        let afterA = PlazaDraw.ended(afterC, word: nil, solver: nil, playing: ["a", "b", "c"], at: 120)
        XCTAssertEqual(afterA.draw?.turn, 4, "b draws its second turn")
    }

    func testTheGameEndsAfterTheLastTurnOrWithFewerThanTwoPlaying() {
        let last = game(order: ["a", "b"], turn: 1, players: ["a", "b"], scores: ["a": 10, "b": 5])
        let done = PlazaDraw.ended(last, word: "x", solver: "a", playing: ["a", "b"], at: 500)
        XCTAssertEqual(done.endedAt, 500)
        XCTAssertEqual(done.draw?.turn, 2)
        XCTAssertEqual(done.winner, "a")
        let tie = PlazaDraw.ended(game(order: ["a", "b"], turn: 1, players: ["a", "b"], scores: ["a": 10, "b": 10]),
                                  word: "x", solver: nil, playing: ["a", "b"], at: 500)
        XCTAssertNotNil(tie.endedAt)
        XCTAssertNil(tie.winner)
        let alone = PlazaDraw.ended(game(order: ["a", "b", "c"]), word: "x", solver: nil, playing: ["a"], at: 50)
        XCTAssertEqual(alone.endedAt, 50)
        XCTAssertEqual(alone.draw?.turn, 3)
        let gameGoesOn = PlazaDraw.ended(game(order: ["a", "b", "c"]), word: "x", solver: nil, playing: ["a", "b"], at: 50)
        XCTAssertNil(gameGoesOn.endedAt, "two are still playing and a turn of theirs is left")
    }

    func testTheRankingIsByScoreThenId() {
        var s = game()
        s.draw?.scores = ["b": 10, "c": 15]
        let r = PlazaDraw.ranking(s)
        XCTAssertEqual(r.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(r.map(\.score), [15, 10, 0])
    }

    func testTheKeysOrderProgress() {
        XCTAssertEqual(PlazaDraw.keys(nil), [-1, -1, -1])
        var d = PlazaDrawState(order: ["a", "b"], turn: 1, step: 4, scores: [:])
        XCTAssertEqual(PlazaDraw.keys(d), [1, 4, 0])
        d.last = .init(turn: 0, drawer: "a", word: "x", solver: nil)
        XCTAssertEqual(PlazaDraw.keys(d), [1, 4, 1])
    }

    // MARK: - Bounds

    func testAPayloadOutOfBoundsIsRefusedAndABadWordIsOnlyRemoved() {
        let players = ["a", "b", "c"]
        let good = PlazaDrawState(order: ["a", "b", "c"], turn: 1, step: 3, scores: ["a": 10, "b": 5])
        XCTAssertEqual(PlazaDraw.accepted(good, players: players), good)
        func refused(_ edit: (inout PlazaDrawState) -> Void, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
            var d = good
            edit(&d)
            XCTAssertNil(PlazaDraw.accepted(d, players: players), message, file: file, line: line)
        }
        refused({ $0.order = Array(repeating: "a", count: 9) }, "9 turns")
        refused({ $0.order = [] }, "no turns")
        refused({ $0.turn = -1 }, "turn -1")
        refused({ $0.turn = 4 }, "turn above the count")
        refused({ $0.step = -1 }, "negative step")
        refused({ $0.order = ["a", "z", "c"] }, "a drawer who is no player")
        refused({ $0.scores = ["a": 31] }, "score above the cap")
        refused({ $0.scores = ["a": -1] }, "negative score")
        refused({ $0.scores = ["z": 5] }, "score of a stranger")
        refused({ $0.initials = String(repeating: "ㅅ", count: 20) }, "long initials")
        refused({ $0.letters = 99 }, "too many letters")
        refused({ $0.last = .init(turn: 0, drawer: "z", word: nil, solver: nil) }, "result of a stranger")
        refused({ $0.entryAt = .nan }, "a time that is not a number")
        XCTAssertNotNil(PlazaDraw.accepted({ var d = good; d.turn = 3; return d }(), players: players), "turn == count: every turn is done")

        for bad in ["1234567890123", "a\u{7}b", "사과!"] {
            var d = good
            d.last = .init(turn: 0, drawer: "a", word: bad, solver: "b")
            let kept = PlazaDraw.accepted(d, players: players)
            XCTAssertNotNil(kept, bad)
            XCTAssertNil(kept?.last?.word, bad)
            XCTAssertEqual(kept?.last?.solver, "b")
            XCTAssertEqual(kept?.last?.drawer, "a")
        }
        var heavy = good
        let weighty = String(repeating: "e\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}", count: 12)
        heavy.last = .init(turn: 0, drawer: "a", word: weighty, solver: "b")
        let trimmed = PlazaDraw.accepted(heavy, players: players)
        XCTAssertNotNil(trimmed, "the payload stays")
        XCTAssertNil(trimmed?.last?.word, "the oversized word goes")
        XCTAssertEqual(trimmed?.last?.solver, "b")
        refused({ $0.initials = String(repeating: "e\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}", count: 12) }, "initials over 64 bytes")
        var fine = good
        fine.last = .init(turn: 0, drawer: "a", word: "사과", solver: nil)
        XCTAssertEqual(PlazaDraw.accepted(fine, players: players)?.last?.word, "사과")
    }
}
