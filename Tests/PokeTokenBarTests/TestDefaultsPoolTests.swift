import XCTest

/// Pins the bound on simultaneous suite plists (see `TestDefaults`): the cfprefsd handle count follows
/// the number of existing plists, so the number of distinct physical domains must not follow the number
/// of tests. These use a private pool prefix so they never touch the shared pool.
final class TestDefaultsPoolTests: XCTestCase {
    private func makePool() -> TestDefaults {
        let pool = TestDefaults(prefix: "ptb.test.pooltest\(UUID().uuidString.prefix(8))")
        addTeardownBlock {
            for _ in 0..<3 { _ = pool.sweep(); Thread.sleep(forTimeInterval: 0.2) }
        }
        return pool
    }

    func testTwoScopesAskingFiftyNamesEachUseAtMostFiftyDomains() {
        let pool = makePool()
        for _ in 0..<2 {
            pool.beginTestCase()
            for i in 0..<50 { _ = pool.open("name-\(UUID())-\(i)") }
            pool.endTestCase()
        }
        XCTAssertEqual(pool.physicalDomains.count, 50)
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
}
