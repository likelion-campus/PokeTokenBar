#if os(Windows)
import Foundation

/// Foundation hands out paths with forward slashes (`C:/Users/x/AppData/Local`) while `NSHomeDirectory()` uses
/// backslashes, so Windows code compares paths normalized and gives Win32 shell APIs native ones.
enum WinPath {
    /// Backslashes, no trailing separator (a drive root keeps its one: `C:\`).
    static func native(_ url: URL) -> String {
        var p = url.path.replacingOccurrences(of: "/", with: "\\")
        while p.count > 3, p.hasSuffix("\\") { p.removeLast() }
        return p
    }

    /// Same location, ignoring case and separator style.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        native(a.standardizedFileURL).lowercased() == native(b.standardizedFileURL).lowercased()
    }
}
#endif
