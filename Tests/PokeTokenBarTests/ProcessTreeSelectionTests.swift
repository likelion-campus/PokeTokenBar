import XCTest
@testable import PokeTokenBar

/// The rule `PlatformCompat.terminate` uses on Windows to find what a `.cmd` shim started (`ProcessTreeSelection`). The snapshot
/// records each process's parent as its creator's id at creation time, and ids are reused: before run 44207854338's fix a process
/// whose creator had exited, and whose creator's id now belonged to the shim or its child, was taken for a descendant and killed.
/// The root is 100, created at 500 unless a test says otherwise; we are 50, created at 1.
final class ProcessTreeSelectionTests: XCTestCase {
    private typealias Link = ProcessTreeSelection.Link
    private let us: UInt32 = 50
    private let snapshot: UInt64 = 1_000
    private var asked: [UInt32] = []

    private func pick(_ links: [Link], _ times: [UInt32: UInt64], rootCreated: UInt64 = 500, usCreated: UInt64 = 1) -> [UInt32] {
        ProcessTreeSelection.descendants(of: 100, rootCreated: rootCreated, current: us, currentCreated: usCreated, links: links,
                                         snapshotTime: snapshot) { self.asked.append($0); return times[$0] }
    }

    func testChildrenAndGrandchildrenAreTakenDeepestFirst() {
        let links = [Link(pid: us, parent: 4), Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: 300, parent: 200)]
        XCTAssertEqual(pick(links, [us: 1, 200: 510, 300: 520]), [300, 200])
    }

    /// The trigger: an older process recording the root's (reused) id as its parent is not the root's child, and neither is
    /// what it started. In CI that older process was the test process itself (here it is refused twice: as the current process,
    /// and as older than the child whose id it records).
    func testAnOlderProcessThatRecordsAReusedIdIsNotADescendant() {
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100),
                     Link(pid: 900, parent: 100),   // created at 10 by a process that had id 100 then and has exited
                     Link(pid: 901, parent: 900),   // started by that older process after the root existed
                     Link(pid: us, parent: 200)]    // the current process, recording the child's reused id
        XCTAssertEqual(pick(links, [us: 1, 200: 510, 900: 10, 901: 600]), [200])
    }

    /// Newer than the root but older than the process whose id it records: 950 was started at 505 by the process that had id
    /// 200 before the root's child 200 (created at 510) got it. Each child is compared with its own parent, not with the root.
    func testAProcessOlderThanItsRecordedParentIsNotADescendantEvenWhenNewerThanTheRoot() {
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: 950, parent: 200)]
        XCTAssertEqual(pick(links, [200: 510, 950: 505]), [200])
    }

    func testAProcessThatCannotBeOpenedOrIsDatedAfterTheSnapshotIsLeftOutWithWhatItStarted() {
        // 200 is dated after the snapshot (the clock was set back); 300 cannot be opened (no creation time), so 400 under it is
        // not reached either.
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: 300, parent: 100), Link(pid: 400, parent: 300)]
        XCTAssertEqual(pick(links, [200: 2_000, 400: 700]), [])
    }

    func testAProcessCreatedInTheSameTickAsItsParentIsItsChild() {
        XCTAssertEqual(pick([Link(pid: 100, parent: us), Link(pid: 200, parent: 100)], [200: 500]), [200])
    }

    /// We, the root and its child created in one clock tick, and we record the child's id as our creator's (reused): by time we
    /// would pass for its child. The current process is refused by rule, before it is asked about (so never opened).
    func testTheCurrentProcessIsNeverTakenNorAskedAbout() {
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: us, parent: 200)]
        XCTAssertEqual(pick(links, [200: 500, us: 500], usCreated: 500), [200])
        XCTAssertEqual(asked, [200])
    }

    func testNothingIsTakenWhenTheRootIsNotInTheSnapshot() {
        XCTAssertEqual(pick([Link(pid: 200, parent: 100)], [200: 510]), [])
    }

    func testNothingIsTakenWhenTheRootsRecordedParentIsNotUs() {
        XCTAssertEqual(pick([Link(pid: 100, parent: 77), Link(pid: 200, parent: 100)], [200: 510]), [])
    }

    func testNothingIsTakenWhenTheRootIsOlderThanUs() {
        XCTAssertEqual(pick([Link(pid: 100, parent: us), Link(pid: 200, parent: 100)], [200: 510], usCreated: 501), [])
    }
}
