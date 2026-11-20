#if os(Windows)
import Foundation
import WinSDK

/// What can be READ of the machine's toast settings (HKCU only; the app never writes any of them). Quiet hours / Focus
/// assist live in a binary CloudStore blob that is not a stable API, so they are not read: the log says so.
enum WinNotificationState {
    private static let push = "Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications"
    private static let settings = "Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings"
    private static let policy = "Software\\Policies\\Microsoft\\Windows\\CurrentVersion\\PushNotifications"
    private static let explorerPolicy = "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer"

    static func dword(_ subkey: String, _ name: String) -> String {
        switch WinRegistry.bytes(subkey, name) {
        case .value(let bytes):
            guard bytes.count >= 4 else { return "len\(bytes.count)" }
            return String(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        case .missing: return "absent"
        case .failed(let code): return "err\(code)"
        }
    }

    static func describe() -> String {
        let aumid = WinAppUserModelID.id
        let remote = GetSystemMetrics(0x1000 /* SM_REMOTESESSION */) != 0
        return [
            "ToastEnabled=\(dword(push, "ToastEnabled"))",
            "globalToasts=\(dword(settings, "NOC_GLOBAL_SETTING_TOASTS_ENABLED"))",
            "perApp[\(aumid)].Enabled=\(dword(settings + "\\" + aumid, "Enabled"))",
            "perApp.ShowInActionCenter=\(dword(settings + "\\" + aumid, "ShowInActionCenter"))",
            "policy.NoToastApplicationNotification=\(dword(policy, "NoToastApplicationNotification"))",
            "policy.DisableNotificationCenter=\(dword(explorerPolicy, "DisableNotificationCenter"))",
            "remoteSession=\(remote)",
            "processAppId=\(WinAppUserModelID.current() ?? "none")",
            "focusAssist/quietHours=not readable (binary CloudStore blob)",
        ].joined(separator: "; ")
    }
}
#endif
