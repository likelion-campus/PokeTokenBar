/// Which processes of a snapshot are really descendants of a process we started (`WinProcessTree`, Windows). Pure, so the rule
/// is tested on both systems.
///
/// A snapshot records each process's parent as the id of its creator at creation time, and Windows reuses process ids: a process
/// whose creator has exited looks like a child of whatever process got that id next. Taking parent ids alone counted such
/// processes as a `.cmd` shim's descendants and killed them (run 44207854338: the test process died). A child counts only when it
/// was created no earlier than its parent and no later than the snapshot; an older process (the current process and its
/// ancestors are always older than a child we started) is left out, and so is everything under it.
enum ProcessTreeSelection {
    struct Link: Equatable, Sendable {
        let pid: UInt32
        let parent: UInt32
    }

    /// The processes under `root`, deepest first. `created` answers a process's creation time, or nil when it cannot be opened.
    static func descendants(of root: UInt32, rootCreated: UInt64, links: [Link], snapshotTime: UInt64,
                            created: (UInt32) -> UInt64?) -> [UInt32] {
        var children: [UInt32: [UInt32]] = [:]
        for link in links where link.pid != link.parent { children[link.parent, default: []].append(link.pid) }
        var accepted: [UInt32] = []
        var seen: Set<UInt32> = [root]
        var pending: [(pid: UInt32, created: UInt64)] = [(root, rootCreated)]
        while let parent = pending.popLast() {
            for child in children[parent.pid] ?? [] where !seen.contains(child) {
                guard let time = created(child), time >= parent.created, time <= snapshotTime else { continue }
                seen.insert(child)
                accepted.append(child)
                pending.append((child, time))
            }
        }
        return accepted.reversed()
    }
}
