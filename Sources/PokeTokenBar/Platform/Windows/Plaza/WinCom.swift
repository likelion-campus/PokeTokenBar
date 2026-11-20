#if os(Windows)
import CPlazaD2D
import Foundation

/// The UI thread's COM apartment. The Korean IME (TSF), the emoji panel and drag-and-drop expect the thread that owns the
/// windows to be a single-threaded apartment, and the process main thread is that thread (Track B F4, F16).
/// `WindowsApp.main` calls `initializeUIThread()` before anything else touches COM; worker threads that use WIC get an MTA
/// on their own (`CPlazaD2D` does it once per thread), and the main thread, being an STA, is used as it is.
enum WinCom {
    struct Apartment: Equatable, Sendable, CustomStringConvertible {
        /// `CO_E_NOTINITIALIZED` (0x800401F0) when the thread has no apartment.
        let hresult: Int32
        /// APTTYPE: 0 STA, 1 MTA, 2 NA, 3 main STA; -1 when there is none.
        let type: Int
        /// APTTYPEQUALIFIER: 1 = the implicit MTA (a thread that never initialised COM but lives in a process that has an MTA).
        let qualifier: Int

        var isSTA: Bool { hresult >= 0 && (type == 0 || type == 3) }
        var isMTA: Bool { hresult >= 0 && type == 1 }

        var description: String {
            guard hresult >= 0 else { return "none(0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))" }
            let names = ["STA", "MTA", "NA", "MAINSTA"]
            let name = type >= 0 && type < names.count ? names[type] : "type\(type)"
            return qualifier == 0 ? name : "\(name)/qualifier\(qualifier)"
        }
    }

    /// What the main thread was before `initializeUIThread` ran (measured first thing in `WindowsApp.main`).
    nonisolated(unsafe) static private(set) var atLaunch: Apartment?
    /// What `CoInitializeEx(STA)` returned (0 or 1 = the thread is an STA now; 0x80010106 = it was an MTA already).
    nonisolated(unsafe) static private(set) var initializeResult: Int32?

    /// The calling thread's apartment right now.
    static func current() -> Apartment {
        var type: Int32 = -1, qualifier: Int32 = 0
        let code = ptb_com_apartment(&type, &qualifier)
        return Apartment(hresult: code, type: code >= 0 ? Int(type) : -1, qualifier: code >= 0 ? Int(qualifier) : 0)
    }

    /// Makes the calling thread an STA (what the main thread gets at launch). Tests use it on a thread of their own.
    static func makeCurrentThreadSTA() -> Int32 { ptb_com_init_sta() }

    /// Main thread only, once, at the very start of launch. A failure is logged (the app still runs; the selftest check fails).
    static func initializeUIThread() {
        atLaunch = current()
        let code = makeCurrentThreadSTA()
        initializeResult = code
        if code < 0 { AppLog.write("COM: the UI thread is not an STA (\(WinPlazaCodecs.lastError()))") }
    }
}
#endif
