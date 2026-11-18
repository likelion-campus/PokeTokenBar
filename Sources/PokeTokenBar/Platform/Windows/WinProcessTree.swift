#if os(Windows)
import Foundation
import WinSDK

/// Ends a process we started and the processes it started (`PlatformCompat.terminate`; an npm `.cmd` shim leaves its program
/// running when only the shim ends, F19), without touching anything else. Which processes count is `ProcessTreeSelection`'s rule
/// (a reused process id made unrelated processes look like children; run 44207854338 killed the test process).
///
/// Every process it ends is held by an open handle from before the snapshot its choice is made on: an open handle keeps its
/// process object, so the id cannot pass to another process while it is held, and the snapshot's line for that id is about that
/// process. The root is held first, through corelibs' own handle (pinned below), before any snapshot. The descendants are opened
/// while walking a first snapshot, which may already be stale (a listed process can exit and its id be reused before it is
/// opened; at the root that is common, because `ProcessRunner` closes the child's stdin just before it terminates it). So the
/// choice is made again on a second snapshot taken after they are all open, with creation times only from those handles, and
/// only that choice is ended.
///
/// Accepted limits (defect log, run 44207854338): a real descendant is missed when it was created after the first snapshot,
/// when a process between it and the root has exited (the chain is broken; if a snapshot leaves out an exited process we still
/// hold, that includes the root exiting before the second snapshot), and when the clock was set back (see
/// `ProcessTreeSelection`). A Job Object around the root right after `process.run()` would remove the guessing; it is not done
/// here.
enum WinProcessTree {
    /// Ends `process` (with corelibs' terminate code) and its descendants (exit code 1), deepest first. False when `process`
    /// could not be pinned (it is not running, or corelibs' handle was already closed), so nothing at all is ended, or when
    /// `TerminateProcess` on the root failed.
    @discardableResult
    static func terminate(_ process: Process) -> Bool {
        guard let root = pin(process) else { return false }
        defer { CloseHandle(root) }
        endDescendants(of: root)
        return TerminateProcess(root, UINT(0xC000_0000 | 15))  // what corelibs' Process.terminate() uses (SIGTERM)
    }

    /// A handle of our own to `process`'s process object, or nil. corelibs sets `isRunning` to false before it closes
    /// `processHandle` (swift-corelibs-foundation 6.3.2 `Process.terminateRunLoop`), so a process still running after the copy
    /// means the value was still its handle when it was copied, never a closed value reused for something else.
    private static func pin(_ process: Process) -> HANDLE? {
        guard process.isRunning else { return nil }
        let me = GetCurrentProcess()
        var copy: HANDLE?
        guard DuplicateHandle(me, process.processHandle, me, &copy, 0, false, DWORD(DUPLICATE_SAME_ACCESS)), let copy else { return nil }
        guard process.isRunning, GetProcessId(copy) == DWORD(process.processIdentifier) else {
            CloseHandle(copy)
            return nil
        }
        return copy
    }

    private static func endDescendants(of root: HANDLE) {
        let rootPID = GetProcessId(root), me = GetCurrentProcessId()
        guard let rootCreated = creationTime(of: root), let meCreated = creationTime(of: GetCurrentProcess()),
              let first = snapshot() else { return }
        func select(_ snapshot: (links: [ProcessTreeSelection.Link], time: UInt64), _ created: (DWORD) -> UInt64?) -> [DWORD] {
            ProcessTreeSelection.descendants(of: rootPID, rootCreated: rootCreated, current: me, currentCreated: meCreated,
                                             links: snapshot.links, snapshotTime: snapshot.time, created: created)
        }
        var opened: [DWORD: (handle: HANDLE, created: UInt64)] = [:]
        defer { for process in opened.values { CloseHandle(process.handle) } }
        _ = select(first) { pid in
            guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
            guard let time = creationTime(of: handle) else { CloseHandle(handle); return nil }
            opened[pid] = (handle, time)
            return time
        }
        guard !opened.isEmpty, let second = snapshot() else { return }
        for pid in select(second, { opened[$0]?.created }) {
            if let process = opened[pid] { TerminateProcess(process.handle, 1) }
        }
    }

    /// Every process's id and recorded parent id, and the time read just after (no process in it was created later, unless the
    /// clock was set back).
    private static func snapshot() -> (links: [ProcessTreeSelection.Link], time: UInt64)? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE else { return nil }
        var links: [ProcessTreeSelection.Link] = []
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        if Process32FirstW(snapshot, &entry) {
            repeat { links.append(.init(pid: entry.th32ProcessID, parent: entry.th32ParentProcessID)) } while Process32NextW(snapshot, &entry)
        }
        CloseHandle(snapshot)
        return (links, now())
    }

    static func creationTime(of handle: HANDLE) -> UInt64? {
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &creation, &exit, &kernel, &user) else { return nil }
        return UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime)
    }

    private static func now() -> UInt64 {
        var time = FILETIME()
        GetSystemTimePreciseAsFileTime(&time)
        return UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)
    }
}
#endif
