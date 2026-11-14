// P12: does `CredReadW` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = CredReadW
let w = CredWriteW
let d = CredDeleteW
let credFree = CredFree
withExtendedLifetime((f, w, d, credFree)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = CredReadW(nil, 0, 0, nil)
    _ = CredWriteW(nil, 0)
    _ = CredDeleteW(nil, 0, 0)
    CredFree(nil)
}
print("cov CredReadW linked")
