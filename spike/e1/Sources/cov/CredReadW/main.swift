// P12: does `CredReadW` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = CredReadW
let w = CredWriteW
let d = CredDeleteW
let credFree = CredFree
withExtendedLifetime((f, w, d, credFree)) {}
print("cov CredReadW linked")
