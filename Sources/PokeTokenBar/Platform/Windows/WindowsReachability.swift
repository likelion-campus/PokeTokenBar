#if os(Windows)
import Foundation
import WinSDK

/// What one registration's callback talks to. The Windows callback runs on a pool thread with a raw pointer to this
/// object, so it outlives `stop()` by a grace period (a callback may be in flight when the cancel returns), and
/// `close()` makes every later or queued delivery a no-op: nothing reaches `onChange` after `stop()`.
final class WinReachabilityContext: @unchecked Sendable {
    static let cancelGrace: TimeInterval = 5
    private let lock = NSLock()
    private var open = true
    private var retained: Unmanaged<WinReachabilityContext>?
    private let onChange: @Sendable (Bool) -> Void
    private(set) var deliveries = 0

    init(onChange: @escaping @Sendable (Bool) -> Void) { self.onChange = onChange }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }

    /// Any thread. Hops to the main queue (never `assumeIsolated`: this is a pool thread, F16) and re-checks there.
    func receive(isSatisfied: Bool) {
        guard isOpen else { return }
        DispatchQueue.main.async { [self] in
            guard isOpen else { return }
            lock.lock(); deliveries += 1; lock.unlock()
            onChange(isSatisfied)
        }
    }

    func close() { lock.lock(); open = false; lock.unlock() }

    func retainForWindows() -> UnsafeMutableRawPointer {
        let u = Unmanaged.passRetained(self)
        lock.lock(); retained = u; lock.unlock()
        return u.toOpaque()
    }

    func releaseRetain() {
        lock.lock(); let u = retained; retained = nil; lock.unlock()
        u?.release()
    }

    func releaseRetainAfterGrace() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) { self.releaseRetain() }
    }
}

/// `NL_NETWORK_CONNECTIVITY_LEVEL_HINT`: 3 internet access, 4 constrained internet access count as "satisfied"
/// (what `NWPath.Status.satisfied` means on the Mac); unknown (0), none (1), local access (2), hidden (5) do not.
func winConnectivityIsSatisfied(_ rawLevel: Int) -> Bool { rawLevel == 3 || rawLevel == 4 }

private func winReachabilityHint(_ context: UnsafeMutableRawPointer?, _ hint: NL_NETWORK_CONNECTIVITY_HINT) {
    guard let context else { return }
    let ctx = Unmanaged<WinReachabilityContext>.fromOpaque(context).takeUnretainedValue()
    ctx.receive(isSatisfied: winConnectivityIsSatisfied(Int(hint.ConnectivityLevel.rawValue)))
}

/// The Windows `NetworkReachabilityMonitor`: `NotifyNetworkConnectivityHintChange` with an initial notification,
/// the same "came back" rule and cooldown as the Mac (`ReachabilityTransition`), the callback on the main queue.
/// Event-driven: nothing wakes the process unless Windows reports a connectivity change.
final class WindowsReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var transition: ReachabilityTransition
    private let clock: @Sendable () -> Date
    private var handle: HANDLE?
    private var context: WinReachabilityContext?
    private var callback: (@Sendable () -> Void)?
    private var observed = 0
    private static let unavailableLogged = WinOnce()

    init(cooldown: TimeInterval = 5, clock: @escaping @Sendable () -> Date = { Date() }) {
        transition = ReachabilityTransition(cooldown: cooldown)
        self.clock = clock
    }

    var onReconnected: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }

    /// Connectivity observations delivered since `start()` (the initial one counts). For the selftest.
    var observations: Int { lock.lock(); defer { lock.unlock() }; return observed }
    var currentContext: WinReachabilityContext? { lock.lock(); defer { lock.unlock() }; return context }
    /// False when the registration failed (logged once); the monitor then never reports a reconnect.
    private(set) var isAvailable = true

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard context == nil else { return }
        let ctx = WinReachabilityContext { [weak self] satisfied in self?.apply(isSatisfied: satisfied) }
        var registration: HANDLE?
        let status = NotifyNetworkConnectivityHintChange(winReachabilityHint, ctx.retainForWindows(), 1, &registration)
        guard status == 0 else {
            ctx.close()
            ctx.releaseRetain()
            isAvailable = false
            if Self.unavailableLogged.first() {
                AppLog.write("network reachability unavailable: NotifyNetworkConnectivityHintChange failed (\(status)); no reconnect refresh")
            }
            return
        }
        handle = registration
        context = ctx
    }

    func stop() {
        lock.lock()
        let ctx = context, registration = handle
        context = nil; handle = nil
        transition.reset()
        lock.unlock()
        guard let ctx else { return }
        ctx.close()  // before the cancel: an in-flight or queued delivery becomes a no-op
        if let registration { _ = CancelMibChangeNotify2(registration) }
        ctx.releaseRetainAfterGrace()
    }

    deinit { stop() }

    /// Main queue only (the context delivers there).
    private func apply(isSatisfied: Bool) {
        lock.lock()
        observed += 1
        let trigger = transition.update(isSatisfied: isSatisfied, now: clock())
        let cb = callback
        lock.unlock()
        guard trigger else { return }
        AppLog.write("network reconnected — triggering refresh")
        cb?()
    }
}

struct WindowsNetworkWatching: NetworkWatching {
    func makeReachabilityMonitor() -> any ReachabilityMonitoring { WindowsReachabilityMonitor() }
}
#endif
