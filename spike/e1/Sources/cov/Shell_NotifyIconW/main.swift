// P12: does `Shell_NotifyIconW` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = Shell_NotifyIconW
var data = NOTIFYICONDATAW()
data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
let r = Shell_NotifyIconGetRect
withExtendedLifetime((f, data, r)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = Shell_NotifyIconW(0, nil)
    _ = Shell_NotifyIconGetRect(nil, nil)
}
print("cov Shell_NotifyIconW linked")
