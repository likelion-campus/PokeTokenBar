import XCTest

/// The only place in `Tests/` allowed to create a `UserDefaults` suite.
///
/// Every suite writes a `<suite>.plist` into `~/Library/Preferences`, and the cfprefsd agent keeps one
/// directory handle open for every such plist that still exists (measured: 50 suites -> 51 handles, and
/// deleting the files brings it back to 1). A UUID-named suite per test therefore makes the handle count
/// grow with the number of tests until cfprefsd hits its limit (~508), stops serving preferences and does
/// not recover even after the files are deleted. `removePersistentDomain(forName:)` does not help: it
/// empties the domain but leaves a ~50-byte plist behind.
///
/// So the number of distinct domains is bounded instead of deleted afterwards. Inside one test case each
/// requested name maps to a physical suite `ptb.test.pool.<pid>.<n>` taken from a pool: the same name gives
/// the same `UserDefaults` object (re-opening a store works), a different name gets the next slot. The
/// pid keeps concurrent `swift test` processes off each other's domains. The pool only grows to the
/// largest number of distinct names a single test asks for, a slot is wiped before it is handed out again
/// and when the test ends, and a test that asks for more than `maxNamesPerTest` names fails (reuse one
/// name, or see the defect log entry on cfprefsd). A request made outside any test case (after one
/// finished and before the next starts) uses a separate pool of at most `externalLimit` slots, reused
/// round-robin.
///
/// A pooled slot outlives its test, so a store that does too (an un-awaited refresh `Task`, a timer) could
/// save into the slot after the next test was handed it: the real usage ledger of the developer's machine
/// once landed in `UsageLedgerRecordingTests` that way. So the object a test receives is a `PooledDefaults`
/// that is *closed* when the test ends (or the slot is handed on): from then on its writes are dropped. A
/// late write can then only reach an object nobody reads, while the physical domains stay bounded.
///
/// cfprefsd writes dirty domains a few seconds *after* the last change, and writes them again if the file
/// is deleted before that. So when the bundle finishes this deletes every pool plist of this process
/// (`ptb.test.pool*.<pid>.*`), then keeps sweeping until cfprefsd's delayed writes have landed and been
/// deleted too. The first request also deletes pool plists of processes that no longer exist. That costs a few seconds once per
/// `swift test` run. `TestDefaultsScanTests` fails if any other file calls the raw initializer.
/// The `UserDefaults` handed to a test. Behaves like a normal suite until `close()`, then drops every write.
final class PooledDefaults: UserDefaults, @unchecked Sendable {
    private let gate = NSRecursiveLock()   // super.set(Int...) calls back into set(_:forKey:)
    private var closed = false

    override init?(suiteName suitename: String?) { super.init(suiteName: suitename) }

    func close() { gate.lock(); closed = true; gate.unlock() }
    var isClosed: Bool { gate.lock(); defer { gate.unlock() }; return closed }

    /// Runs `write` unless closed. The gate is held across the write so close() cannot interleave with it.
    private func ifOpen(_ write: () -> Void) {
        gate.lock(); defer { gate.unlock() }
        if !closed { write() }
    }

    override func set(_ value: Any?, forKey defaultName: String) { ifOpen { super.set(value, forKey: defaultName) } }
    override func set(_ value: Int, forKey defaultName: String) { ifOpen { super.set(value, forKey: defaultName) } }
    override func set(_ value: Float, forKey defaultName: String) { ifOpen { super.set(value, forKey: defaultName) } }
    override func set(_ value: Double, forKey defaultName: String) { ifOpen { super.set(value, forKey: defaultName) } }
    override func set(_ value: Bool, forKey defaultName: String) { ifOpen { super.set(value, forKey: defaultName) } }
    override func set(_ url: URL?, forKey defaultName: String) { ifOpen { super.set(url, forKey: defaultName) } }
    override func removeObject(forKey defaultName: String) { ifOpen { super.removeObject(forKey: defaultName) } }
}

final class TestDefaults: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = TestDefaults()
    private static let externalLimit = 8
    /// Distinct suite names one test may open. The biggest legitimate test needs a handful.
    static let maxNamesPerTest = 32
    private static let poolFilePrefix = "ptb.test.pool"

    private let lock = NSLock()
    private let prefix: String
    private var slots: [Int: PooledDefaults] = [:]
    private var scope: [String: Int] = [:]
    private var inTestCase = false
    private var externalScope: [String: Int] = [:]
    private var externalNext = 0
    private var observing = false
    private var capReported = false
    /// Called (once per test) when a test exceeds `maxNamesPerTest`. Tests of the pool replace it.
    var onCapExceeded: @Sendable (String) -> Void = { XCTFail($0) }

    /// `prefix` names the physical domains (`<prefix>.<n>`, external ones `<prefix>.ext.<n>`). Only the
    /// shared instance is used by tests; the pool's own tests build one with a private prefix.
    init(prefix: String = "ptb.test.pool.\(getpid())") {
        self.prefix = prefix
    }

    /// Opens `suite` like `UserDefaults(suiteName:)` would. The name is only a key: the domain behind
    /// it is a pooled one that is empty when handed out. Calling it again with the same name inside one
    /// test case (to re-open a store) returns the same object.
    static func make(suite: String) -> UserDefaults {
        ensureObserving()
        return shared.open(suite)
    }

    /// Registers the shared pool's observer (idempotent). `make` does it; the pool's own tests call it so
    /// the bundle-end sweep also runs when only they are selected.
    static func ensureObserving() { shared.registerOnce() }

    private func registerOnce() {
        lock.lock()
        let needsObserver = !observing
        observing = true
        // The first request normally comes from inside a test whose start we could not observe yet.
        if needsObserver { inTestCase = true }
        lock.unlock()
        if needsObserver {
            Self.removeStalePlists(in: NSHomeDirectory() + "/Library/Preferences")
            XCTestObservationCenter.shared.addTestObserver(self)
        }
    }

    func open(_ suite: String) -> UserDefaults {
        lock.lock()
        var overflow = false
        defer {
            lock.unlock()
            if overflow {
                onCapExceeded("a test opened more than \(Self.maxNamesPerTest) distinct UserDefaults suites. "
                    + "Every suite's plist costs cfprefsd a directory fd and enough of them wedge it; reuse one "
                    + "suite name (see docs/reference/defect-log.md, cfprefsd entry).")
            }
        }
        if inTestCase {
            if let n = scope[suite] { return slots[n]! }
            var n = scope.count
            if n >= Self.maxNamesPerTest {
                // Stay usable: every name past the cap shares the one overflow slot.
                n = Self.maxNamesPerTest
                if !capReported { capReported = true; overflow = true }
            }
            scope[suite] = n
            return handOut(slot: n, domain: "\(prefix).\(n)", key: n)
        }
        if let n = externalScope[suite] { return slots[Self.externalKey(n)]! }
        let n = externalNext
        externalNext = (externalNext + 1) % Self.externalLimit
        externalScope = externalScope.filter { $0.value != n }
        externalScope[suite] = n
        return handOut(slot: n, domain: "\(prefix).ext.\(n)", key: Self.externalKey(n))
    }

    private static func externalKey(_ n: Int) -> Int { -1 - n }

    /// Returns a new open object on the slot's domain, which is empty. The previous holder's object is closed.
    private func handOut(slot: Int, domain: String, key: Int) -> UserDefaults {
        slots[key]?.close()
        let defaults = PooledDefaults(suiteName: domain)!
        slots[key] = defaults
        Self.wipe(defaults, domain: domain)
        return defaults
    }

    /// Empties a domain. `removePersistentDomain` clears the cached values and schedules the write;
    /// `synchronize` pushes it to cfprefsd so the next reader (a re-used slot, or a second object on the
    /// same domain) cannot see the old keys.
    static func wipe(_ defaults: UserDefaults, domain: String) {
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
    }

    func beginTestCase() {
        lock.lock()
        inTestCase = true
        scope = [:]
        capReported = false
        lock.unlock()
    }

    func endTestCase() {
        lock.lock()
        for n in scope.values {
            Self.wipe(slots[n]!, domain: "\(prefix).\(n)")
            slots[n]!.close()
        }
        scope = [:]
        inTestCase = false
        lock.unlock()
    }

    func testCaseWillStart(_ testCase: XCTestCase) { beginTestCase() }
    func testCaseDidFinish(_ testCase: XCTestCase) { endTestCase() }

    /// Physical domain names created so far.
    var physicalDomains: [String] {
        lock.lock()
        defer { lock.unlock() }
        return slots.keys.sorted().map { $0 >= 0 ? "\(prefix).\($0)" : "\(prefix).ext.\(-1 - $0)" }
    }

    /// Deletes this instance's pool plists that exist right now and returns how many there were.
    func sweep() -> Int {
        let names = physicalDomains
        lock.lock()
        let all = Array(slots.values)
        lock.unlock()
        for defaults in all { defaults.synchronize() }
        return Self.removeFiles(named: names, in: NSHomeDirectory() + "/Library/Preferences")
    }

    private static func removeFiles(named names: [String], in dir: String) -> Int {
        var removed = 0
        for name in names where (try? FileManager.default.removeItem(atPath: "\(dir)/\(name).plist")) != nil {
            removed += 1
        }
        return removed
    }

    /// Pid inside `ptb.test.pool.<pid>.…` / `ptb.test.pooltest.<pid>.…`, nil for other files.
    static func poolPid(ofFile file: String) -> Int32? {
        guard file.hasPrefix(poolFilePrefix), file.hasSuffix(".plist") else { return nil }
        var rest = file.dropFirst(poolFilePrefix.count)
        if rest.hasPrefix("test") { rest = rest.dropFirst(4) }
        guard rest.hasPrefix(".") else { return nil }
        return rest.dropFirst().split(separator: ".").first.flatMap { Int32($0) }
    }

    /// Whether a process with this pid exists. Windows has no `kill(pid, 0)`; there every owner counts as alive,
    /// so nothing is swept (the pool lives under `~/Library/Preferences`, which Windows does not have).
    static func processIsAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        return true
        #else
        return kill(pid, 0) == 0 || errno != ESRCH
        #endif
    }

    /// Deletes every pool plist in `dir` whose owner process is gone (crashed runs). `isAlive` is injectable.
    @discardableResult
    static func removeStalePlists(in dir: String,
                                  isAlive: (Int32) -> Bool = processIsAlive) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var removed = 0
        for file in files {
            guard let pid = poolPid(ofFile: file), pid != ProcessInfo.processInfo.processIdentifier, !isAlive(pid) else { continue }
            if (try? FileManager.default.removeItem(atPath: "\(dir)/\(file)")) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes every pool plist of this process (the shared pool and the pool tests' own pools).
    private func sweepProcessFiles() -> Int {
        lock.lock()
        let all = Array(slots.values)
        lock.unlock()
        for defaults in all { defaults.synchronize() }
        let dir = NSHomeDirectory() + "/Library/Preferences"
        let mine = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let names = mine.filter { Self.poolPid(ofFile: $0) == getpid() }.map { String($0.dropLast(".plist".count)) }
        return Self.removeFiles(named: names, in: dir)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let start = Date()
        var lastRemoval = start
        // Delayed writes land in batches a few seconds after the last change, so keep sweeping until at
        // least 10 s have passed and the last 4 s found nothing new (hard stop at 25 s).
        while Date().timeIntervalSince(start) < 25 {
            if sweepProcessFiles() > 0 { lastRemoval = Date() }
            if Date().timeIntervalSince(start) >= 10, Date().timeIntervalSince(lastRemoval) >= 4 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
