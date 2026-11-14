// P12: does `MiniDumpWriteDump` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = MiniDumpWriteDump
let s = SetUnhandledExceptionFilter
withExtendedLifetime((f, s)) {}
print("cov MiniDumpWriteDump linked")
