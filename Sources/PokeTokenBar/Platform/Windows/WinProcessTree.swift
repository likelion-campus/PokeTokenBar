#if os(Windows)
import WinSDK

/// Ends a process we started and the processes it started (`PlatformCompat.terminate`; an npm `.cmd` shim leaves its program
/// running when only the shim ends, F19), without touching anything else. Which processes count is `ProcessTreeSelection`'s rule
/// (a reused process id made unrelated processes look like children; run 44207854338 killed the test process). The root must be our
/// own child. Each accepted process is opened before anything is ended, and is ended through that handle: an open handle keeps its
/// process object, so its id cannot be reused under us.
enum WinProcessTree {
    /// Ends `rootPID` (with corelibs' terminate code) and its descendants (exit code 1), deepest first. False when the root could
    /// not be confirmed as our own running child (gone, its id reused, or no snapshot): then nothing is ended.
    @discardableResult
    static func terminate(rootPID: DWORD) -> Bool {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE else { return false }
        var links: [ProcessTreeSelection.Link] = []
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        if Process32FirstW(snapshot, &entry) {
            repeat { links.append(.init(pid: entry.th32ProcessID, parent: entry.th32ParentProcessID)) } while Process32NextW(snapshot, &entry)
        }
        CloseHandle(snapshot)
        let snapshotTime = now()  // after the snapshot: everything in it was created by then; a process made later is not in it

        var handles: [DWORD: HANDLE] = [:]
        defer { for handle in handles.values { CloseHandle(handle) } }
        func created(_ pid: DWORD) -> UInt64? {
            guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
            guard let time = creationTime(of: handle), time <= snapshotTime else { CloseHandle(handle); return nil }
            handles[pid] = handle
            return time
        }
        let me = GetCurrentProcessId()
        guard links.contains(.init(pid: rootPID, parent: me)), let selfCreated = creationTime(of: GetCurrentProcess()),
              let rootCreated = created(rootPID), rootCreated >= selfCreated, let rootHandle = handles[rootPID]
        else { return false }
        let tree = ProcessTreeSelection.descendants(of: rootPID, rootCreated: rootCreated, links: links, snapshotTime: snapshotTime,
                                                    created: created)
        for pid in tree { if let handle = handles[pid] { TerminateProcess(handle, 1) } }
        TerminateProcess(rootHandle, UINT(0xC000_0000 | 15))  // what corelibs' Process.terminate() uses (SIGTERM)
        return true
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
