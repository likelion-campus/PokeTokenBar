#if os(Windows)
import Foundation

/// Task 8: the notifier on the live tray. Balloon calls only run on CI (they would show on a person's PC, like
/// `tray.balloon`); the permission and unavailable checks show nothing and always run.
extension WindowsSelftest {
    @MainActor static func notifyChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray, let notifier = Platform.current.notifications as? WindowsNotifications else {
            r.add("notify.permission", false, "Platform.current.notifications is not the Windows notifier")
            return
        }
        let tray = host.tray, presenter = notifier.presenter
        let ci = ProcessInfo.processInfo.environment["CI"] != nil

        let authorized = await notifier.requestAuthorization()
        r.add("notify.permission", notifier.isAvailable == tray.isPresent && authorized == tray.isPresent && tray.isPresent,
              "isAvailable=\(notifier.isAvailable) requestAuthorization=\(authorized) tray present=\(tray.isPresent) (no OS prompt exists)")

        if ci {
            let shown0 = presenter.shownCount
            notifier.post(id: "selftest-1", title: "PokeTokenBar self-test", body: "한국어 😀 balloon", sound: false)
            r.add("notify.post", presenter.shownCount == shown0 + 1 && tray.lastBalloonOK && presenter.inFlight?.id == "selftest-1",
                  "shell call returned \(tray.lastBalloonOK) flags=0x\(String(tray.lastBalloonFlags, radix: 16)) shown \(shown0) -> \(presenter.shownCount) (visibility is a PC check)")
            presenter.handle(.hidden)

            let shown1 = presenter.shownCount
            for i in 1...3 { notifier.post(id: "q\(i)", title: "q\(i)", body: "queue", sound: false) }
            let afterPost = (presenter.shownCount - shown1, presenter.pendingCount, presenter.lastShown?.id ?? "-")
            presenter.handle(.timedOut)
            presenter.handle(.clicked)
            let afterTwo = presenter.lastShown?.id ?? "-"
            presenter.handle(.hidden)
            r.add("notify.queue", afterPost == (1, 2, "q1") && afterTwo == "q3" && presenter.inFlight == nil
                  && presenter.shownCount == shown1 + 3 && !presenter.isWatchdogArmed,
                  "3 quick posts: shown/pending/first=\(afterPost); after 2 finishes last=\(afterTwo); in flight=\(presenter.inFlight?.id ?? "none"); watchdog armed=\(presenter.isWatchdogArmed)")

            notifier.post(id: "clip", title: String(repeating: "한", count: 90), body: String(repeating: "😀", count: 200), sound: false)
            r.add("notify.clip", presenter.lastTitleUnits <= BalloonQueue.titleLimit && presenter.lastBodyUnits <= BalloonQueue.bodyLimit && tray.lastBalloonOK,
                  "title 90 -> \(presenter.lastTitleUnits) units (limit \(BalloonQueue.titleLimit)), body 400 -> \(presenter.lastBodyUnits) (limit \(BalloonQueue.bodyLimit)) shell=\(tray.lastBalloonOK)")
            presenter.handle(.hidden)
        } else {
            r.add("notify.post", true, "skipped (not CI): a balloon would show on this PC")
        }

        // No tray icon: the notifier says so and claims nothing.
        tray.remove()
        let failed0 = presenter.failedCount, shown2 = presenter.shownCount
        let authorizedWithout = await notifier.requestAuthorization()
        notifier.post(id: "gone", title: "t", body: "b", sound: false)
        let unavailable = !notifier.isAvailable && !authorizedWithout && presenter.failedCount == failed0 + 1 && presenter.shownCount == shown2
        let readded = tray.add()
        host.refresh()
        r.add("notify.unavailable", unavailable && readded,
              "without the tray icon: available=\(!unavailable) authorized=\(authorizedWithout) failures \(failed0) -> \(presenter.failedCount) shown unchanged=\(presenter.shownCount == shown2); icon added back=\(readded)")
    }
}
#endif
