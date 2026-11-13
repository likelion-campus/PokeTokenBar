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
/// requested name maps to a physical suite `ptb.test.pool.<n>` taken from a pool: the same name gives the
/// same `UserDefaults` object (re-opening a store works), a different name gets the next slot. The pool
/// only grows to the largest number of distinct names a single test asks for, and a slot is wiped before
/// it is handed out again and when the test ends. A request made outside any test case (after one
/// finished and before the next starts) uses a separate pool of at most `externalLimit` slots, reused
/// round-robin.
///
/// cfprefsd writes dirty domains a few seconds *after* the last change, and writes them again if the file
/// is deleted before that. So when the bundle finishes this deletes every pool plist, then keeps sweeping
/// until cfprefsd's delayed writes have landed and been deleted too. That costs a few seconds once per
/// `swift test` run. `TestDefaultsScanTests` fails if any other file calls the raw initializer.
final class TestDefaults: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = TestDefaults()
    private static let externalLimit = 8

    private let lock = NSLock()
    private let prefix: String
    private var slots: [Int: UserDefaults] = [:]
    private var scope: [String: Int] = [:]
    private var inTestCase = false
    private var externalScope: [String: Int] = [:]
    private var externalNext = 0
    private var observing = false

    /// `prefix` names the physical domains (`<prefix>.<n>`, external ones `<prefix>.ext.<n>`). Only the
    /// shared instance is used by tests; the pool's own tests build one with a private prefix.
    init(prefix: String = "ptb.test.pool") {
        self.prefix = prefix
    }

    /// Opens `suite` like `UserDefaults(suiteName:)` would. The name is only a key: the domain behind
    /// it is a pooled one that is empty when handed out. Calling it again with the same name inside one
    /// test case (to re-open a store) returns the same object.
    static func make(suite: String) -> UserDefaults {
        shared.registerOnce()
        return shared.open(suite)
    }

    private func registerOnce() {
        lock.lock()
        let needsObserver = !observing
        observing = true
        // The first request normally comes from inside a test whose start we could not observe yet.
        if needsObserver { inTestCase = true }
        lock.unlock()
        if needsObserver { XCTestObservationCenter.shared.addTestObserver(self) }
    }

    func open(_ suite: String) -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        if inTestCase {
            if let n = scope[suite] { return slots[n]! }
            let n = scope.count
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

    /// Returns the slot's object, creating it on first use, with an empty domain.
    private func handOut(slot: Int, domain: String, key: Int) -> UserDefaults {
        let defaults = slots[key] ?? UserDefaults(suiteName: domain)!
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
        lock.unlock()
    }

    func endTestCase() {
        lock.lock()
        for n in scope.values { Self.wipe(slots[n]!, domain: "\(prefix).\(n)") }
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

    /// Deletes the plists that exist right now and returns how many there were.
    func sweep() -> Int {
        let names = physicalDomains
        lock.lock()
        let all = Array(slots.values)
        lock.unlock()
        for defaults in all { defaults.synchronize() }
        let dir = NSHomeDirectory() + "/Library/Preferences"
        var removed = 0
        for name in names where (try? FileManager.default.removeItem(atPath: "\(dir)/\(name).plist")) != nil {
            removed += 1
        }
        return removed
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let start = Date()
        var lastRemoval = start
        // Delayed writes land in batches a few seconds after the last change, so keep sweeping until at
        // least 10 s have passed and the last 4 s found nothing new (hard stop at 25 s).
        while Date().timeIntervalSince(start) < 25 {
            if sweep() > 0 { lastRemoval = Date() }
            if Date().timeIntervalSince(start) >= 10, Date().timeIntervalSince(lastRemoval) >= 4 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
