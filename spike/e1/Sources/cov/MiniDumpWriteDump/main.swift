// P12: does `MiniDumpWriteDump` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = MiniDumpWriteDump
let s = SetUnhandledExceptionFilter
withExtendedLifetime((f, s)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = MiniDumpWriteDump(nil, 0, nil, MiniDumpNormal, nil, nil, nil)
    _ = SetUnhandledExceptionFilter(nil)
}
print("cov MiniDumpWriteDump linked")
