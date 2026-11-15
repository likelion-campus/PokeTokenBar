#if os(Windows)
import Foundation
import WinSDK

/// The process's explicit AppUserModelID. The installer puts the same id on its Start-menu shortcut
/// (`AppUserModelID:` in `installer/PokeTokenBar.iss`), which is what lets Windows attribute the toast it makes of a tray
/// balloon to "PokeTokenBar", keep it in the notification centre and list the app under Settings > Notifications.
/// A scan test (`WindowsAppUserModelIDScanTests`) keeps the three spellings equal. Per-user, no registry write.
enum WinAppUserModelID {
    static let id = "LikelionCampus.PokeTokenBar"

    private typealias SetFn = @convention(c) (UnsafePointer<UInt16>?) -> Int32
    private typealias GetFn = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>?) -> Int32

    /// HRESULT of the last `set` (0 = S_OK), for the selftest and the log.
    nonisolated(unsafe) private(set) static var lastHResult: Int32 = -1

    @discardableResult
    static func set(_ value: String = id) -> Bool {
        guard let fn = WinDynamic.symbol("shell32.dll", "SetCurrentProcessExplicitAppUserModelID", as: SetFn.self) else {
            AppLog.write("app id: SetCurrentProcessExplicitAppUserModelID is not available")
            return false
        }
        lastHResult = WinStr.w(value).withUnsafeBufferPointer { fn($0.baseAddress) }
        if lastHResult != 0 { AppLog.write("app id: SetCurrentProcessExplicitAppUserModelID failed 0x\(String(UInt32(bitPattern: lastHResult), radix: 16))") }
        return lastHResult == 0
    }

    /// What the shell holds for this process right now.
    static func current() -> String? {
        guard let fn = WinDynamic.symbol("shell32.dll", "GetCurrentProcessExplicitAppUserModelID", as: GetFn.self) else { return nil }
        var out: UnsafeMutablePointer<UInt16>?
        guard fn(&out) == 0, let out else { return nil }
        defer { CoTaskMemFree(out) }
        return String(decodingCString: out, as: UTF16.self)
    }
}
#endif
