// P12: does `WSAPoll` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = WSAPoll
let fd = WSAPOLLFD()
withExtendedLifetime((f, fd)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = WSAPoll(nil, 0, 0)
}
print("cov WSAPoll linked")
