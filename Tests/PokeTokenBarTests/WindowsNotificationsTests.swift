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
        XCTAssertNotEqual(tray.lastBalloonFlags & WinTray.niifRespectQuietTime, 0)
        XCTAssertTrue(tray.showBalloon(title: "PokeTokenBar test", body: "body", sound: true))
        XCTAssertEqual(tray.lastBalloonFlags & DWORD(NIIF_NOSOUND), 0, "sound == true")
        XCTAssertNotEqual(tray.lastBalloonFlags & WinTray.niifRespectQuietTime, 0, "quiet time is respected either way")
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
}
#endif
