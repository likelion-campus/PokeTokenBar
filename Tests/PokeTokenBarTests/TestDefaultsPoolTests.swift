import XCTest

/// Pins the bound on simultaneous suite plists (see `TestDefaults`): the cfprefsd handle count follows
/// the number of existing plists, so the number of distinct physical domains must not follow the number
/// of tests. These use a private pool prefix so they never touch the shared pool.
final class TestDefaultsPoolTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The pool's bundle-end sweep also deletes this test's files (`ptb.test.pooltest.<pid>.*`), even
        // when only these tests are selected.
        TestDefaults.ensureObserving()
    }

    private func makePool() -> TestDefaults {
        TestDefaults(prefix: "ptb.test.pooltest.\(getpid())")
    }

    func testTwoScopesAskingThirtyNamesEachUseAtMostThirtyDomains() {
        let pool = makePool()
        for _ in 0..<2 {
            pool.beginTestCase()
            for i in 0..<30 { _ = pool.open("name-\(UUID())-\(i)") }
            pool.endTestCase()
        }
        XCTAssertEqual(pool.physicalDomains.count, 30)
    }

    func testPooledSuiteHandedToANewScopeReadsBackEmpty() {
        let pool = makePool()
        pool.beginTestCase()
        let first = pool.open("a")
        first.set("dirty", forKey: "key")
        first.set(7, forKey: "other")
        XCTAssertEqual(first.string(forKey: "key"), "dirty")
        pool.endTestCase()

        pool.beginTestCase()
        let second = pool.open("b")
        XCTAssertNil(second.object(forKey: "key"))
        XCTAssertNil(second.object(forKey: "other"))
        let domain = pool.physicalDomains[0]
        XCTAssertNil(CFPreferencesCopyAppValue("key" as CFString, domain as CFString), "cfprefsd must not hold the old value either")
        // A write that lands after the owner's scope ended is wiped when the slot is handed out again.
        pool.endTestCase()
        first.set("late", forKey: "late")
        pool.beginTestCase()
        XCTAssertNil(pool.open("c").object(forKey: "late"))
        pool.endTestCase()
    }

    func testReopeningTheSameNameInOneScopeGivesTheSameObject() {
        let pool = makePool()
        pool.beginTestCase()
        let a = pool.open("store")
        a.set(1, forKey: "k")
        let b = pool.open("store")
        XCTAssertTrue(a === b)
        XCTAssertEqual(b.integer(forKey: "k"), 1)
        XCTAssertFalse(pool.open("other") === a)
        pool.endTestCase()
    }

    func testRequestsOutsideAnyTestCaseStayWithinTheExternalLimit() {
        let pool = makePool()
        for i in 0..<30 { _ = pool.open("class-level-\(i)") }
        XCTAssertEqual(pool.physicalDomains.count, 8)
    }

    func testSweepDeletesThePoolPlists() throws {
        let pool = makePool()
        pool.beginTestCase()
        pool.open("x").set(1, forKey: "k")
        pool.endTestCase()
        let path = NSHomeDirectory() + "/Library/Preferences/\(pool.physicalDomains[0]).plist"
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "precondition: cfprefsd wrote the plist")
        XCTAssertGreaterThan(pool.sweep(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testExceedingTheCapReportsOnceAndStillReturnsAUsableStore() {
        let pool = makePool()
        let reports = Reports()
        pool.onCapExceeded = { reports.add($0) }
        pool.beginTestCase()
        var last: UserDefaults?
        for i in 0..<(TestDefaults.maxNamesPerTest + 20) { last = pool.open("n\(i)") }
        pool.endTestCase()
        XCTAssertEqual(reports.messages.count, 1)
        XCTAssertTrue(reports.messages.first?.contains("defect-log") == true)
        XCTAssertLessThanOrEqual(pool.physicalDomains.count, TestDefaults.maxNamesPerTest + 1)
        last?.set(1, forKey: "k")
        XCTAssertEqual(last?.integer(forKey: "k"), 1)
        // The next test case starts clean and under the cap again.
        pool.beginTestCase()
        _ = pool.open("fresh")
        pool.endTestCase()
        XCTAssertEqual(reports.messages.count, 1)
    }

    func testPoolFileNamesCarryTheOwnerPid() {
        XCTAssertEqual(TestDefaults.poolPid(ofFile: "ptb.test.pool.123.4.plist"), 123)
        XCTAssertEqual(TestDefaults.poolPid(ofFile: "ptb.test.pool.123.ext.2.plist"), 123)
        XCTAssertEqual(TestDefaults.poolPid(ofFile: "ptb.test.pooltest.77.0.plist"), 77)
        XCTAssertNil(TestDefaults.poolPid(ofFile: "ptb.test.pool.0.plist.bak"))
        XCTAssertNil(TestDefaults.poolPid(ofFile: "com.apple.dock.plist"))
        XCTAssertNil(TestDefaults.poolPid(ofFile: "ptb.test.pooltestdeadbeef.0.plist"))
    }

    func testStalePlistsOfDeadProcessesAreDeletedAndLiveOnesKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-stale-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dead = "ptb.test.pool.99990.0.plist", live = "ptb.test.pool.99991.0.plist"
        let mine = "ptb.test.pool.\(getpid()).0.plist", other = "com.example.keep.plist"
        for f in [dead, live, mine, other] { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data()) }
        let removed = TestDefaults.removeStalePlists(in: dir.path, isAlive: { $0 != 99990 })
        XCTAssertEqual(removed, 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, [live, mine, other])
    }

    func testRealAliveCheckTreatsMissingPidAsDead() {
        // pid 1 is always alive; a pid beyond the kernel's range never is.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-alive-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["ptb.test.pool.1.0.plist", "ptb.test.pool.2000000000.0.plist"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data())
        }
        XCTAssertEqual(TestDefaults.removeStalePlists(in: dir.path), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ptb.test.pool.1.0.plist").path))
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ m: String) { lock.lock(); items.append(m); lock.unlock() }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
