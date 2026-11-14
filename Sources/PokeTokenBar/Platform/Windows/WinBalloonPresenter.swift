#if os(Windows)
import Foundation

/// Shows `BalloonQueue` items one at a time through the tray icon. A balloon "finishes" on the shell's clicked /
/// hidden / timed-out notification; because newer Windows may turn a balloon into a toast and never send those, a
/// one-shot watchdog (armed only while a balloon is up, never otherwise) ends a balloon that stays silent too long,
/// so the queue cannot stall. Nothing wakes the process while no balloon is showing.
@MainActor final class WinBalloonPresenter {
    static let watchdogSeconds: TimeInterval = 30

    private let tray: WinTray
    private let showBalloon: (String, String, Bool) -> Bool
    private var queue: BalloonQueue
    private var watchdog: Timer?
    private var loggedFailure = false

    var onClick: ((BalloonQueue.Kind) -> Void)?

    /// What the selftest and tests read.
    private(set) var shownCount = 0
    private(set) var failedCount = 0
    private(set) var lastShown: BalloonQueue.Item?
    private(set) var lastTitleUnits = 0
    private(set) var lastBodyUnits = 0
    private(set) var watchdogFires = 0
    var droppedCount: Int { queue.dropped }
    var pendingCount: Int { queue.pendingCount }
    var inFlight: BalloonQueue.Item? { queue.inFlight }
    var isWatchdogArmed: Bool { watchdog != nil }

    init(tray: WinTray, capacity: Int = 5) {
        self.tray = tray
        self.showBalloon = { tray.showBalloon(title: $0, body: $1, sound: $2) }
        queue = BalloonQueue(capacity: capacity)
        tray.onBalloonEvent = { [weak self] event in self?.handle(event) }
    }

    /// False when the balloon could not be handed to the shell (no tray icon, or the call failed); never claims
    /// delivery it does not have. True means the shell accepted it: Windows may still hide it (Focus Assist, the
    /// user's notification settings), which no API reports.
    @discardableResult
    func post(_ item: BalloonQueue.Item) -> Bool {
        guard tray.isPresent else {
            fail("no tray icon")
            return false
        }
        let clipped = BalloonQueue.Item(id: item.id,
                                        title: BalloonQueue.clipped(item.title, limit: BalloonQueue.titleLimit),
                                        body: BalloonQueue.clipped(item.body, limit: BalloonQueue.bodyLimit),
                                        sound: item.sound, kind: item.kind)
        guard var next = queue.offer(clipped) else { return true }  // queued behind the one on screen
        var accepted = false
        while true {
            if display(next) { accepted = true; break }
            guard let after = queue.finished() else { break }  // this one failed: the next waiting one gets its turn
            next = after
        }
        return accepted
    }

    /// The shell's notification for the balloon on screen. Public so a test can drive the sequence.
    func handle(_ event: WinTray.BalloonEvent) {
        guard let current = queue.inFlight else { return }  // a late event for a balloon already ended by the watchdog
        if event == .clicked { onClick?(current.kind) }
        advance()
    }

    // MARK: -

    private func advance() {
        cancelWatchdog()
        while let next = queue.finished() {
            if display(next) { return }
        }
    }

    private func display(_ item: BalloonQueue.Item) -> Bool {
        let ok = showBalloon(item.title, item.body, item.sound)
        if ok {
            shownCount += 1
            lastShown = item
            lastTitleUnits = item.title.utf16.count
            lastBodyUnits = item.body.utf16.count
            armWatchdog()
        } else {
            fail("Shell_NotifyIcon refused the balloon")
        }
        return ok
    }

    private func fail(_ why: String) {
        failedCount += 1
        guard !loggedFailure else { return }
        loggedFailure = true
        AppLog.write("balloon: not delivered (\(why)); further failures are not logged")
    }

    private func armWatchdog() {
        cancelWatchdog()
        let timer = Timer(fire: Date(timeIntervalSinceNow: Self.watchdogSeconds), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchdog = nil
                self.watchdogFires += 1
                self.advance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}
#endif
