// P12: does `NotifyNetworkConnectivityHintChange` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = NotifyNetworkConnectivityHintChange
let g = GetNetworkConnectivityHint
withExtendedLifetime((f, g)) {}
print("cov NotifyNetworkConnectivityHintChange linked")
