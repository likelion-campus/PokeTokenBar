import Foundation

/// Logs one line the first time it is asked, then stays quiet.
private final class LogOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let line: String
    private let sink: @Sendable (String) -> Void
    init(_ line: String, sink: @escaping @Sendable (String) -> Void) { self.line = line; self.sink = sink }
    func fire() {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { sink(line) }
    }
}

/// Contract for an OS without a real implementation yet: do nothing, report "unavailable", log once per service.
/// Compiled on every OS so the Mac test can assert the contract; Windows selects it in `WindowsPlatform.swift`.
enum StubPlatform {
    @MainActor static func make() -> Platform { make(log: { AppLog.write($0) }) }

    /// `log` is injectable so a test can count lines without touching the real log.
    @MainActor static func make(log: @escaping @Sendable (String) -> Void) -> Platform {
        Platform(notifications: StubNotifications(log: log),
                 secrets: StubSecrets(log: log),
                 events: StubSystemEvents(log: log),
                 idle: StubIdleClock(log: log))
    }
}

@MainActor final class StubNotifications: LocalNotifying {
    private let once: LogOnce
    init(log: @escaping @Sendable (String) -> Void) { once = LogOnce("Platform stub: notifications unavailable", sink: log) }
    var isAvailable: Bool { once.fire(); return false }
    func requestAuthorization() async -> Bool { once.fire(); return false }
    func post(id: String, title: String, body: String, sound: Bool) { once.fire() }
}

final class StubSecrets: SecretStoring {
    private let once: LogOnce
    init(log: @escaping @Sendable (String) -> Void) { once = LogOnce("Platform stub: secret store unavailable", sink: log) }
    func read(service: String, account: String?) -> Result<Data, SecretError> { once.fire(); return .failure(.unavailable) }
}

@MainActor final class StubSystemEvents: SystemEvents {
    private let once: LogOnce
    init(log: @escaping @Sendable (String) -> Void) { once = LogOnce("Platform stub: system events never fire", sink: log) }
    func onWake(_ f: @escaping @Sendable () -> Void) { once.fire() }
    func onScreensSleep(_ f: @escaping @Sendable () -> Void) { once.fire() }
    func onScreensWake(_ f: @escaping @Sendable () -> Void) { once.fire() }
    func onDayChange(_ f: @escaping @Sendable () -> Void) { once.fire() }
    var displaysAreAsleep: Bool { once.fire(); return false }
}

final class StubIdleClock: IdleClock {
    private let once: LogOnce
    init(log: @escaping @Sendable (String) -> Void) { once = LogOnce("Platform stub: idle clock reports 0", sink: log) }
    func secondsSinceLastInput() -> TimeInterval { once.fire(); return 0 }
}
