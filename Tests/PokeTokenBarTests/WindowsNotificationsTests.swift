#if os(Windows)
import WinSDK
import XCTest
@testable import PokeTokenBar

/// A real sink window and tray icon (the runner has a working shell tray; whether a balloon is VISIBLE is a PC check).
@MainActor
final class WindowsNotificationsTests: XCTestCase {
    private var window: WinSinkWindow!
    private var tray: WinTray!

    override func setUp() async throws {
        window = try WinSinkWindow(title: "ptb-notifications-test")
        tray = WinTray(window: window)
    }

    override func tearDown() async throws {
        tray.remove()
        window.destroy()
    }

    func testPostCallsShellNotifyIconWithInfo() async throws {
        XCTAssertTrue(tray.add())
        XCTAssertTrue(tray.showBalloon(title: "PokeTokenBar test", body: "body", sound: false))
        XCTAssertTrue(tray.lastBalloonOK, "NIM_MODIFY with NIF_INFO returns TRUE on the runner")
        XCTAssertNotEqual(tray.lastBalloonFlags & DWORD(NIIF_NOSOUND), 0, "sound == false")
        XCTAssertEqual(tray.lastBalloonFlags & BalloonFlags.respectQuietTime, 0, "quiet time must not drop the balloon")
        XCTAssertTrue(tray.showBalloon(title: "PokeTokenBar test", body: "body", sound: true))
        XCTAssertEqual(tray.lastBalloonFlags & DWORD(NIIF_NOSOUND), 0, "sound == true")
        XCTAssertEqual(tray.lastBalloonFlags & BalloonFlags.respectQuietTime, 0)
    }

    func testNoTrayMeansNotAvailableAndNoDeliveryClaim() async {
        let presenter = WinBalloonPresenter(tray: tray)
        let notifier = WindowsNotifications(presenter: presenter, tray: tray)
        XCTAssertFalse(notifier.isAvailable)
        let authorized = await notifier.requestAuthorization()
        XCTAssertFalse(authorized)
        XCTAssertFalse(presenter.post(.init(id: "x", title: "t", body: "b", sound: false, kind: .app)))
        notifier.post(id: "y", title: "t", body: "b", sound: false)
        XCTAssertEqual(presenter.shownCount, 0)
        XCTAssertEqual(presenter.failedCount, 2)
        XCTAssertNil(presenter.inFlight)
    }

    func testSeveralBalloonsShowOneAtATimeInOrder() async {
        XCTAssertTrue(tray.add())
        let presenter = WinBalloonPresenter(tray: tray, capacity: 2)
        let notifier = WindowsNotifications(presenter: presenter, tray: tray)
        let authorized = await notifier.requestAuthorization()
        XCTAssertTrue(notifier.isAvailable && authorized)
        var clicks: [BalloonQueue.Kind] = []
        presenter.onClick = { clicks.append($0) }
        for id in ["1", "2", "3", "4"] { notifier.post(id: id, title: "t\(id)", body: "b", sound: false) }
        XCTAssertEqual(presenter.shownCount, 1, "one at a time")
        XCTAssertEqual(presenter.lastShown?.id, "1")
        XCTAssertEqual(presenter.droppedCount, 1)
        presenter.handle(.clicked)
        XCTAssertEqual(clicks, [.app])
        XCTAssertEqual(presenter.lastShown?.id, "3", "2 was dropped as the oldest waiting")
        presenter.handle(.timedOut)
        XCTAssertEqual(presenter.lastShown?.id, "4")
        presenter.handle(.hidden)
        XCTAssertNil(presenter.inFlight)
        XCTAssertFalse(presenter.isWatchdogArmed, "no timer while nothing is showing")
        presenter.handle(.hidden)  // a late event changes nothing
        XCTAssertEqual(presenter.shownCount, 3)
    }

    func testBalloonTextIsClippedBeforeTheShellSeesIt() async {
        XCTAssertTrue(tray.add())
        let presenter = WinBalloonPresenter(tray: tray)
        XCTAssertTrue(presenter.post(.init(id: "c", title: String(repeating: "한", count: 90),
                                           body: String(repeating: "😀", count: 200), sound: false, kind: .app)))
        XCTAssertLessThanOrEqual(presenter.lastTitleUnits, BalloonQueue.titleLimit)
        XCTAssertLessThanOrEqual(presenter.lastBodyUnits, BalloonQueue.bodyLimit)
        XCTAssertTrue(presenter.lastShown?.body.hasSuffix("…") == true)
    }

    func testShellShownReportIsCountedAndDoesNotAdvanceTheQueue() async {
        XCTAssertTrue(tray.add())
        let presenter = WinBalloonPresenter(tray: tray)
        presenter.post(.init(id: "1", title: "t", body: "b", sound: false, kind: .hint))
        presenter.post(.init(id: "2", title: "t", body: "b", sound: false, kind: .app))
        XCTAssertTrue(presenter.isShownWatchArmed, "armed while a balloon is up")
        presenter.handle(.shown)
        XCTAssertEqual(presenter.shellShownCount, 1)
        XCTAssertFalse(presenter.isShownWatchArmed, "shown: nothing left to wait for")
        XCTAssertEqual(presenter.inFlight?.id, "1", "shown means still on screen: the next one waits")
        presenter.handle(.hidden)
        XCTAssertEqual(presenter.inFlight?.id, "2")
        presenter.handle(.hidden)
        XCTAssertFalse(presenter.isShownWatchArmed)
        XCTAssertEqual(presenter.notShownCount, 0)
    }

    func testABalloonTheShellNeverReportsIsCountedNotShown() async {
        XCTAssertTrue(tray.add())
        let presenter = WinBalloonPresenter(tray: tray)
        presenter.post(.init(id: "1", title: "t", body: "b", sound: false, kind: .app))
        XCTAssertEqual(presenter.notShownCount, 0)
        let deadline = Date().addingTimeInterval(WinBalloonPresenter.shownWithinSeconds + 3)
        while presenter.notShownCount == 0 && presenter.shellShownCount == 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        // Exactly one of the two outcomes: a runner that can show toasts reports it shown (no flake either way).
        XCTAssertEqual(presenter.notShownCount + presenter.shellShownCount, 1, "shown reported, or counted not shown after the window")
        presenter.handle(.hidden)
    }
}
#endif
