// P12: does `RegisterSuspendResumeNotification` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = RegisterSuspendResumeNotification
withExtendedLifetime(f) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    _ = RegisterSuspendResumeNotification(nil, 0)
}
print("cov RegisterSuspendResumeNotification linked")
