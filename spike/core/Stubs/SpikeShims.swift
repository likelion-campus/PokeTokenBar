import Foundation
// Throwaway shims for APIs missing on Windows.
#if os(Windows)
import WinSDK
@discardableResult func spikeKill(_ pid: Int32) -> Int32 {
    guard let h = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return -1 }
    defer { CloseHandle(h) }
    return TerminateProcess(h, 1) ? 0 : -1
}
#else
@discardableResult func spikeKill(_ pid: Int32) -> Int32 { kill(pid, SIGKILL) }
#endif
