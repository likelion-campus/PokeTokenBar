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
}
#endif
