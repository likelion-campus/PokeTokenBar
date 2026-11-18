/// Which processes of a snapshot are really descendants of a process we started (`WinProcessTree`, Windows). Pure, so the rule
/// is tested on both systems.
///
/// A snapshot records each process's parent as the id of its creator at creation time, and Windows reuses process ids: a process
/// whose creator has exited looks like a child of whatever process got that id next. Taking parent ids alone counted such
/// processes as a `.cmd` shim's descendants and killed them (run 44207854338: the test process died). So the root must be, by the
/// snapshot, our own child and not older than us; a child counts only when it was created no earlier than the parent it records
/// (a process holds its id from its creation on, so a process created after it and recording that id was created by it) and not
/// after `snapshotTime` (a later time means the clock was set back); the current process never counts. What is left out is not
/// walked, so nothing under it counts either.
///
/// Times come from the system clock, so the rule has known limits (all of them in the defect log's entry for run 44207854338):
/// a clock set back between two creations mostly makes a real child look older than its parent (a miss), and only rarely makes
/// an unrelated process look newer than the process that took over its creator's id (a wrong accept); two creations in the same
/// clock tick count as parent and child whatever their order.
enum ProcessTreeSelection {
    struct Link: Equatable, Sendable {
        let pid: UInt32
        let parent: UInt32
    }

    /// The processes under `root`, deepest first, or none when the root is not `current`'s child by `links` or is older than
    /// `current`. `links` has one entry a process, as a snapshot does: then each process has one parent, the root's is `current`,
    /// which is never taken, and so no process is reached twice. `created` answers a process's creation time, or nil when it is
    /// not known; it is never asked about `current`.
    static func descendants(of root: UInt32, rootCreated: UInt64, current: UInt32, currentCreated: UInt64, links: [Link],
                            snapshotTime: UInt64, created: (UInt32) -> UInt64?) -> [UInt32] {
        guard links.contains(Link(pid: root, parent: current)), rootCreated >= currentCreated else { return [] }
        var children: [UInt32: [UInt32]] = [:]
        for link in links where link.pid != link.parent { children[link.parent, default: []].append(link.pid) }
        var accepted: [UInt32] = []
        var pending: [(pid: UInt32, created: UInt64)] = [(root, rootCreated)]
        while let parent = pending.popLast() {
            for child in children[parent.pid] ?? [] where child != current {
                guard let time = created(child), time >= parent.created, time <= snapshotTime else { continue }
                accepted.append(child)
                pending.append((child, time))
            }
        }
        return accepted.reversed()
    }
}
