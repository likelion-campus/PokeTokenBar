#if os(Windows)
import Foundation

/// What the installed Windows app looks like on disk. `Bundle.main.bundleIdentifier` is always nil there, so
/// "is this the real app" is decided by a version file the packaging puts next to the exe.
enum WindowsInstall {
    static let versionFileName = "PokeTokenBar.version"
    /// Frozen: the settings file is named after the process name, which includes `.exe`.
    static let shippedExecutableName = "PokeTokenBar.exe"

    /// The version file is present and not empty.
    static func isPackagedLayout(executableDirectory: URL) -> Bool {
        guard let text = try? String(contentsOf: executableDirectory.appendingPathComponent(versionFileName), encoding: .utf8)
        else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `Bundle.main.bundlePath` is the exe's folder on Windows.
    static var isPackagedLayout: Bool {
        isPackagedLayout(executableDirectory: URL(fileURLWithPath: Bundle.main.bundlePath))
    }

    static var version: String? {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent(versionFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The app's working folder leaves the install folder at launch: the Start-menu shortcut and Setup's `[Run]` start
    /// the app there, and every process the app starts inherits it (browsers through `ShellExecuteW`, the CLI probes,
    /// the update's Setup), which keeps that folder from being renamed or removed. The logs folder exists once `AppLog`
    /// has run. Nothing in the app resolves a relative path after launch (CI passes absolute paths).
    @discardableResult static func leaveInstallFolder(for folder: URL = PlatformCompat.logsDirectory()) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ok = FileManager.default.changeCurrentDirectoryPath(WinPath.native(folder))
        AppLog.write("working folder: \(ok ? "" : "not changed, still ")\(FileManager.default.currentDirectoryPath)")
        return ok
    }
}
#endif
