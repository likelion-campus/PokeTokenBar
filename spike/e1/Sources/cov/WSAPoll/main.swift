// P12: does `WSAPoll` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = WSAPoll
let fd = WSAPOLLFD()
withExtendedLifetime((f, fd)) {}
print("cov WSAPoll linked")
