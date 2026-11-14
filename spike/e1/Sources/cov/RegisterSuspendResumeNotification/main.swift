// P12: does `RegisterSuspendResumeNotification` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = RegisterSuspendResumeNotification
withExtendedLifetime(f) {}
print("cov RegisterSuspendResumeNotification linked")
