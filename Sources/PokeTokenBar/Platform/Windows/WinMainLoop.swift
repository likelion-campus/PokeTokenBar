#if os(Windows)
import Foundation
import WinSDK

/// Looks an export up at run time: for calls whose library the target does not link (`userenv`), whose header the
/// importer may not reach, or that are runtime internals (`dispatch.dll`). nil when the module or export is missing.
enum WinDynamic {
    static func symbol<T>(_ module: String, _ name: String, as type: T.Type) -> T? {
        let wide = WinStr.w(module)
        guard let handle = GetModuleHandleW(wide) ?? LoadLibraryExW(wide, nil, 0x0A00 /* LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32 */), let proc = GetProcAddress(handle, name)
        else { return nil }
        return unsafeBitCast(proc, to: type)
    }
}

/// The process main thread's loop (D2, proven by E1). `RunLoop.main` is touched first: its initializer switches on
/// CoreFoundation's Win32 message mask (F4). Then one `RunLoop.main.run(mode: .default, before: .distantFuture)` loop
/// serves Win32 messages, the dispatch main queue (where `@MainActor` work runs) and `RunLoop` timers, and blocks
/// with no wakeup while nothing is due.
enum WinMainLoop {
    enum Strategy: String, Equatable {
        case cfRunLoopWithMessages
        /// Diagnostics only (`PTB_WIN_LOOP=dispatch`): our own `MsgWaitForMultipleObjectsEx` on the main queue's
        /// handle, a `PeekMessageW` pump and timers through `limitDate`. Polling was rejected (E1 P4).
        case dispatchHandle
    }

    nonisolated(unsafe) private static var logged = false
    /// Loop passes on the main thread (the selftest's idle report).
    nonisolated(unsafe) private(set) static var iterations = 0
    /// `run(mode:before:)` answering "nothing to run" (should never happen on the main run loop).
    nonisolated(unsafe) private(set) static var finishedReturns = 0

    /// Win32 constants the importer may not fold (`QS_ALLINPUT` is a macro of macros).
    static let qsAllInput: DWORD = 0x04FF
    static let mwmoInputAvailable: DWORD = 0x0004

    static func prepare(environment: [String: String] = ProcessInfo.processInfo.environment) -> Strategy {
        _ = RunLoop.main
        let strategy: Strategy = environment["PTB_WIN_LOOP"]?.lowercased() == "dispatch" ? .dispatchHandle
            : .cfRunLoopWithMessages
        if !logged {
            logged = true
            AppLog.write("main loop: \(strategy.rawValue)")
        }
        return strategy
    }

    @MainActor static func run(_ strategy: Strategy, until done: @escaping @MainActor () -> Bool) {
        switch strategy {
        case .cfRunLoopWithMessages:
            while !done() {
                if !RunLoop.main.run(mode: .default, before: .distantFuture) { finishedReturns += 1 }
                iterations += 1
            }
        case .dispatchHandle:
            guard let loop = DispatchHandleLoop() else {
                AppLog.write("main loop: dispatch.dll exports missing; using \(Strategy.cfRunLoopWithMessages.rawValue)")
                run(.cfRunLoopWithMessages, until: done)
                return
            }
            loop.run(until: done)
        }
    }

    fileprivate static func noteIteration() { iterations += 1 }
}

/// E1's `dh` loop. The two dispatch symbols are exported by `dispatch.dll` (E1 P1). Anything that touches
/// `RunLoop.main` (shared `UsageStore` does) leaves CF's ANSI pump on inside `limitDate`; the message hook still
/// fixes characters there.
private struct DispatchHandleLoop {
    typealias PortFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias DrainFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let port: PortFn
    let drain: DrainFn

    init?() {
        guard let port = WinDynamic.symbol("dispatch.dll", "_dispatch_get_main_queue_port_4CF", as: PortFn.self),
              let drain = WinDynamic.symbol("dispatch.dll", "_dispatch_main_queue_callback_4CF", as: DrainFn.self)
        else { return nil }
        self.port = port
        self.drain = drain
    }

    @MainActor func run(until done: @MainActor () -> Bool) {
        guard let handle = port() else { return }
        var msg = MSG()
        while !done() {
            let next = RunLoop.main.limitDate(forMode: .default)  // runs due timers
            if done() { return }
            var timeout: DWORD = 60_000
            if let next {
                let ms = next.timeIntervalSinceNow * 1000
                timeout = ms <= 1 ? 1 : (ms >= 60_000 ? 60_000 : DWORD(ms.rounded(.up)))
            }
            var handles: [HANDLE?] = [handle]
            let r = MsgWaitForMultipleObjectsEx(1, &handles, timeout, WinMainLoop.qsAllInput,
                                                WinMainLoop.mwmoInputAvailable)
            WinMainLoop.noteIteration()
            if r == 0 {
                drain(nil)
            } else if r == 1 {
                while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                    _ = TranslateMessage(&msg)
                    _ = DispatchMessageW(&msg)
                }
            }
        }
    }
}
#endif
