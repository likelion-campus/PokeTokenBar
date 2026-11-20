#if os(Windows)
import WinSDK

/// A thread of our own for one blocking job, its handle closed as soon as it exists.
///
/// `Foundation.Thread` on Windows keeps the handle `_beginthreadex` returns and never closes it (swift-corelibs-foundation
/// `Sources/Foundation/Thread.swift`, swift-6.3.2-RELEASE and main: `start()` stores it in `_thread`; the file has no
/// `CloseHandle` of it and no `deinit`). Every `Thread { }.start()` therefore leaves one handle, and the exited thread's kernel
/// object, for the life of the process: the PokéAPI base index built over REST (649 fetches) left about 600 handles in the idle
/// gate (run 44143290510). A thread keeps running after its handle is closed ("Closing a thread handle does not terminate the
/// associated thread or remove the thread object", `CloseHandle`). For work started per operation; a thread started once per
/// process may stay a `Thread`.
enum WinDetachedThread {
    private final class Job: Sendable {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }

    /// Runs `body` on a new thread. False when Windows could not create one: `body` never runs, so the caller answers itself.
    static func start(_ body: @escaping @Sendable () -> Void) -> Bool {
        let job = Unmanaged.passRetained(Job(body)).toOpaque()
        guard let handle = CreateThread(nil, 0, { raw in
            guard let raw else { return 0 }
            Unmanaged<Job>.fromOpaque(raw).takeRetainedValue().body()
            return 0
        }, job, 0, nil) else {
            Unmanaged<Job>.fromOpaque(job).release()
            return false
        }
        _ = CloseHandle(handle)
        return true
    }
}
#endif
