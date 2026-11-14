// P12: does `RegisterPowerSettingNotification` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = RegisterPowerSettingNotification
let guid = GUID_CONSOLE_DISPLAY_STATE
withExtendedLifetime((f, guid)) {}
// Forces a real symbol reference the optimizer cannot drop (never true at runtime).
if CommandLine.arguments.count > 1000 {
    var g = GUID_CONSOLE_DISPLAY_STATE
    _ = RegisterPowerSettingNotification(nil, &g, 0)
}
print("cov RegisterPowerSettingNotification linked")
