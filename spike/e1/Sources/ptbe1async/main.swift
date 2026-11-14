// Throwaway (Track B experiment E1, P6 / guess G-b): what an async main does to the main thread on Windows.
import CE1Shim
import Foundation

let ctor = e1_ctor_tid()
let entryTid = e1_tid()
e1_log("E1.P6 VALUE entry tid=\(entryTid) ctor_tid=\(ctor) entry_on_main=\(entryTid == ctor) ctor_thread_alive=\(e1_thread_alive(ctor))")
let hwnd = e1_make_window(0)
let creator = e1_tid()
e1_log("E1.P6 VALUE window created=\(hwnd != nil) creator_tid=\(creator)")
try? await Task.sleep(nanoseconds: 300_000_000)
let after = e1_tid()
let alive = e1_thread_alive(ctor)
let isWin = e1_is_window(hwnd)
e1_log("E1.P6 VALUE after-first-await tid=\(after) on_main=\(after == ctor) on_creator=\(after == creator) "
    + "ctor_thread_alive=\(alive) creator_alive=\(e1_thread_alive(creator)) isWindow=\(isWin) window_thread=\(e1_window_thread(hwnd))")
e1_start_poster(hwnd, 3, 50, 0)
try? await Task.sleep(nanoseconds: 1_000_000_000)
var med = 0.0, mx = 0.0
var onm: Int32 = 0
let delivered = e1_poster_stats(&med, &mx, &onm)
let mainActorTid = await MainActor.run { e1_tid() }
let dqTid: UInt32 = await withCheckedContinuation { c in
    DispatchQueue.main.async { c.resume(returning: e1_tid()) }
}
let keeps = after == ctor && alive == 1 && isWin == 1
e1_log("E1.P6 \(keeps ? "PASS" : "FAIL") async-main-keeps-the-main-thread-and-window after_await_on_main=\(after == ctor) "
    + "ctor_thread_alive=\(alive) isWindow=\(isWin) posted=3 delivered(no pump)=\(delivered) MainActor.run_tid=\(mainActorTid) "
    + "DispatchQueue.main_tid=\(dqTid) ctor_tid=\(ctor)")
exit(0)
