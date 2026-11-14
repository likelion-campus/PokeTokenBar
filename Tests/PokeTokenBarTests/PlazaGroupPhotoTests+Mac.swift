// PlazaGroupPhotoTests+Mac: the tests that expect the photo on the clipboard writer; that needs a PNG codec, which the Windows stub graphics do not have
import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaGroupPhotoTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// G starts a five-second countdown here and on teammates' plazas, then flashes and puts my photo on the clipboard.
    func testGStartsACountdownThatEndsInMyPhoto() async throws {
        let (_, other, c) = await connected()
        var received: [TeamEmote] = []
        other.session.onEmote = { received.append($1) }
        pressG(c)
        pressG(c, isRepeat: true)
        XCTAssertTrue(c.isPhotoMode, "G opens photo mode")
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!")
        await waitUntil { !received.isEmpty }
        XCTAssertEqual(received, [TeamEmote(kind: .groupPhoto, targetMemberID: nil)])
        for left in [4, 3, 2, 1] {
            await tick()
            XCTAssertEqual(c.countdown, "단체 사진 \(left) · 모두 모여요!")
        }
        XCTAssertTrue(written.isEmpty)
        await tick()
        XCTAssertNil(c.countdown)
        XCTAssertEqual(written.count, 1, "one photo")
        XCTAssertTrue(c.isPhotoMode, "photo mode stays on after the group photo")
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing)
        XCTAssertEqual(received.count, 1, "the held G sent nothing more")
    }

    /// A teammate's countdown flashes my plaza too but leaves my clipboard alone, unless I am in photo mode (P),
    /// which sends nothing.
    func testTeammatesCountdownTakesMyPhotoOnlyInPhotoMode() async throws {
        let (_, other, c) = await connected()
        let id = other.settings.memberID
        var received = 0
        other.session.onEmote = { _, _ in received += 1 }
        c.showGroupPhoto(from: id)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 5 · P를 누르면 함께 찍어요")
        for _ in 0..<5 { await tick() }
        XCTAssertNil(c.countdown)
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing, "everyone sees the flash")
        XCTAssertTrue(written.isEmpty, "my clipboard is not touched")

        c.showGroupPhoto(from: id)
        await tick()
        pressP(c)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 4 · 함께 찍는 중")
        for _ in 0..<4 { await tick() }
        XCTAssertNil(c.countdown)
        XCTAssertEqual(written.count, 1, "in photo mode, so my photo is taken")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received, 0, "taking part sends nothing")
    }

    /// G during a teammate's countdown enters photo mode, which is the joining; it sends nothing.
    func testGDuringATeammatesCountdownJoinsWithoutSending() async {
        let (_, other, c) = await connected()
        var received = 0
        other.session.onEmote = { _, _ in received += 1 }
        c.showGroupPhoto(from: other.settings.memberID)
        pressG(c)
        XCTAssertTrue(c.isPhotoMode)
        XCTAssertEqual(c.countdown, "민수님의 단체 사진 5 · 함께 찍는 중")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(received, 0)
        for _ in 0..<5 { await tick() }
        XCTAssertEqual(written.count, 1)
    }

    /// A photo that cannot be written still flashes at zero: every screen flashes, whatever happens to the clipboard.
    func testAFailedPhotoStillFlashesAtZero() async throws {
        let (_, _, c) = await connected()
        writeSucceeds = false
        pressG(c)
        for _ in 0..<5 { await tick() }
        XCTAssertNil(c.countdown)
        XCTAssertEqual(written.count, 1, "the write was attempted")
        XCTAssertTrue(try XCTUnwrap(c.scene).isShutterFlashing)
        c.handleClose()
    }

    /// Closing the plaza mid-countdown cancels it. Reopened and started again within the five seconds, the old
    /// countdown's next second does nothing: the new one keeps its own count, and only it takes the photo.
    func testClosingThePlazaCancelsTheCountdown() async {
        let (_, _, c) = await connected()
        pressG(c)
        await tick()
        await waitUntil { gate.count > 0 }   // the old countdown waits on its second second
        c.handleClose()
        XCTAssertNil(c.countdown)
        c.prepareScene()
        pressG(c)
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!", "a new one starts")
        gate.tick()   // the old countdown wakes first
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(c.countdown, "단체 사진 5 · 모두 모여요!", "the old countdown does not count the new one down")
        for left in [4, 3, 2, 1] {
            await tick()
            XCTAssertEqual(c.countdown, "단체 사진 \(left) · 모두 모여요!")
        }
        XCTAssertTrue(written.isEmpty)
        await tick()
        XCTAssertEqual(written.count, 1, "one photo, from the new countdown")
    }
}
