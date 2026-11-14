// P12: does `RegisterPowerSettingNotification` import from WinSDK and link? Compile + link is the test; nothing is called.
import WinSDK

let f = RegisterPowerSettingNotification
let guid = GUID_CONSOLE_DISPLAY_STATE
withExtendedLifetime((f, guid)) {}
print("cov RegisterPowerSettingNotification linked")
