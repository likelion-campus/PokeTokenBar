#if os(Windows)
import Foundation
import WinSDK

/// Launch at login through the per-user Run key: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. No scheduled
/// task, no HKLM, nothing that needs elevation. The value is `"<exe path>" --autostart`, quoted, and it names the
/// CURRENT executable: a value that points somewhere else (the folder was moved, the app was reinstalled elsewhere)
/// reads as off, and only the user's toggle ever writes or removes it. First run leaves the key alone.
@MainActor struct WindowsLoginItem {
    static let defaultRunKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    static let defaultApprovedKey = #"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"#
    static let defaultValueName = "PokeTokenBar"

    let runKey: String
    let approvedKey: String
    let valueName: String
    let command: String

    init(runKey: String = WindowsLoginItem.defaultRunKey, approvedKey: String = WindowsLoginItem.defaultApprovedKey,
         valueName: String = WindowsLoginItem.defaultValueName, command: String = WindowsLoginItem.defaultCommand) {
        self.runKey = runKey
        self.approvedKey = approvedKey
        self.valueName = valueName
        self.command = command
    }

    /// `"C:\...\PokeTokenBar.exe" --autostart` for the exe that is running now.
    static var defaultCommand: String { command(forExecutable: currentExecutablePath()) }

    static func command(forExecutable path: String) -> String { "\"\(path)\" --autostart" }

    static func currentExecutablePath() -> String {
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer.prefix(n), as: UTF16.self)
    }

    /// Reads only. `StartupApproved\Run` is what Task Manager's Startup tab writes: an odd first byte (0x03) means
    /// the user turned the entry off there (community-known, undocumented), no entry means enabled.
    var state: TrayMenuModel.LoginState {
        switch WinRegistry.string(runKey, valueName) {
        case .failed: return .unavailable
        case .missing: return .off
        case .value(let existing):
            guard Self.sameCommand(existing, command) else { return .off }
            if case .value(let flags) = WinRegistry.bytes(approvedKey, valueName), let first = flags.first, first & 1 == 1 {
                return .disabledByUser
            }
            return .on
        }
    }

    /// true only when the registry holds the wanted result afterwards (read back, not assumed).
    func setEnabled(_ on: Bool) -> Bool {
        if on {
            let status = WinRegistry.setString(runKey, valueName, command)
            guard status == 0 else {
                AppLog.write("login item: writing the Run value failed (\(status))")
                return false
            }
            guard case .value(let written) = WinRegistry.string(runKey, valueName), Self.sameCommand(written, command) else {
                AppLog.write("login item: the Run value did not read back")
                return false
            }
            return true
        }
        let removed = WinRegistry.deleteValue(runKey, valueName)
        _ = WinRegistry.deleteValue(approvedKey, valueName)  // our own leftover, or "disabled" would stick to the next enable
        guard removed == 0 else {
            AppLog.write("login item: removing the Run value failed (\(removed))")
            return false
        }
        guard case .missing = WinRegistry.string(runKey, valueName) else {
            AppLog.write("login item: the Run value is still there")
            return false
        }
        return true
    }

    /// Windows paths ignore case.
    static func sameCommand(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
#endif
