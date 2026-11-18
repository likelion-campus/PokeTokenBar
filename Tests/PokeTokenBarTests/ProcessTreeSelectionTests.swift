import XCTest
@testable import PokeTokenBar

/// The rule `PlatformCompat.terminate` uses on Windows to find what a `.cmd` shim started (`ProcessTreeSelection`). The snapshot
/// records each process's parent as its creator's id at creation time, and ids are reused: before run 44207854338's fix a process
/// whose creator had exited, and whose creator's id now belonged to the shim or its child, was taken for a descendant and killed.
final class ProcessTreeSelectionTests: XCTestCase {
    private typealias Link = ProcessTreeSelection.Link
    private let us: UInt32 = 50
    private let snapshot: UInt64 = 1_000

    private func pick(_ links: [Link], _ times: [UInt32: UInt64]) -> [UInt32] {
        ProcessTreeSelection.descendants(of: 100, rootCreated: times[100] ?? 0, links: links, snapshotTime: snapshot) { times[$0] }
    }

    func testChildrenAndGrandchildrenAreTakenDeepestFirst() {
        let links = [Link(pid: us, parent: 4), Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: 300, parent: 200)]
        XCTAssertEqual(pick(links, [us: 1, 100: 500, 200: 510, 300: 520]), [300, 200])
    }

    /// The trigger: an older process recording the root's (reused) id as its parent is not the root's child, and neither is
    /// what it started. In CI that older process was the test process itself (it, and every ancestor, is older than its child).
    func testAnOlderProcessThatRecordsAReusedIdIsNotADescendant() {
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100),
                     Link(pid: 900, parent: 100),   // created at 10 by a process that had id 100 then and has exited
                     Link(pid: 901, parent: 900),   // started by that older process after the root existed
                     Link(pid: us, parent: 200)]    // the current process, recording the child's reused id
        XCTAssertEqual(pick(links, [us: 1, 100: 500, 200: 510, 900: 10, 901: 600]), [200])
    }

    func testAProcessMadeAfterTheSnapshotOrThatCannotBeOpenedIsLeftOutWithWhatItStarted() {
        // 200's id was reused after the snapshot; 300 cannot be opened (no creation time), so 400 under it is not reached either.
        let links = [Link(pid: 100, parent: us), Link(pid: 200, parent: 100), Link(pid: 300, parent: 100), Link(pid: 400, parent: 300)]
        XCTAssertEqual(pick(links, [100: 500, 200: 2_000, 400: 700]), [])
    }

    func testAProcessCreatedInTheSameTickAsItsParentIsItsChild() {
        XCTAssertEqual(pick([Link(pid: 100, parent: us), Link(pid: 200, parent: 100)], [100: 500, 200: 500]), [200])
    }
}
