// P12: does `GetLastInputInfo` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = GetLastInputInfo
var info = LASTINPUTINFO()
info.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
withExtendedLifetime((f, info)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = GetLastInputInfo(nil)
}
print("cov GetLastInputInfo linked")
