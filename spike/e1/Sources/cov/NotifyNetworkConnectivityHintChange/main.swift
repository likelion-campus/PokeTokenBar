// P12: does `NotifyNetworkConnectivityHintChange` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = NotifyNetworkConnectivityHintChange
let g = GetNetworkConnectivityHint
withExtendedLifetime((f, g)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = NotifyNetworkConnectivityHintChange(nil, nil, 0, nil)
    _ = GetNetworkConnectivityHint(nil)
}
print("cov NotifyNetworkConnectivityHintChange linked")
