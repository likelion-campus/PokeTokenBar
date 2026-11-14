// P12: does `GetLastInputInfo` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = GetLastInputInfo
var info = LASTINPUTINFO()
info.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
withExtendedLifetime((f, info)) {}
print("cov GetLastInputInfo linked")
