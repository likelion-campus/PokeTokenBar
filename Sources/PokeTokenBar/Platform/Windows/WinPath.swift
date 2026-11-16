#if os(Windows)
import Foundation
import WinSDK   // stage 7 Task 14: finalPath

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

// --- stage 7 Task 14: the final path of an existing file or folder (begin) ---
extension WinPath {
    /// The path Windows itself reports for an existing file or folder (`GetFinalPathNameByHandleW`, `VOLUME_NAME_DOS`): links
    /// and junctions followed, a subst or mapped drive replaced by what it points at, in the `\\?\` device spelling
    /// (`\\?\C:\x`, `\\?\UNC\server\share\x`). nil when it cannot be opened (missing, no access). No access is asked for: the
    /// handle only names the object. On a share that does not answer this waits as long as any file call there does.
    static func finalPath(_ path: String) -> String? {
        let native = path.replacingOccurrences(of: "/", with: "\\")
        let handle = native.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(0x7) /* FILE_SHARE_READ | WRITE | DELETE */, nil, DWORD(3) /* OPEN_EXISTING */,
                        DWORD(0x0200_0000) /* FILE_FLAG_BACKUP_SEMANTICS: a folder too */, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var buffer = [UInt16](repeating: 0, count: 512)
        var n = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), 0 /* FILE_NAME_NORMALIZED | VOLUME_NAME_DOS */)
        if n >= DWORD(buffer.count) {
            buffer = [UInt16](repeating: 0, count: Int(n) + 1)
            n = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), 0)
        }
        guard n > 0, n < DWORD(buffer.count) else { return nil }
        return String(decoding: buffer[0..<Int(n)], as: UTF16.self)
    }
}
// --- stage 7 Task 14 (end) ---
#endif
