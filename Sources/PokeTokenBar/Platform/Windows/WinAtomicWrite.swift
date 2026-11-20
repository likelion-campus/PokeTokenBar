#if os(Windows)
import Foundation
import WinSDK

/// `PlatformCompat.atomicWrite` on Windows: temporary file in the same folder, then `MoveFileExW(REPLACE_EXISTING)`.
/// No FlushFileBuffers and no MOVEFILE_WRITE_THROUGH: a power cut right after a save can lose that save, and without a
/// flush NTFS may even commit the rename before the data reaches the disk (the same exposure as `Data.write(.atomic)`
/// on the Mac, accepted by the ruling); a crash or kill never leaves a half-written destination. MoveFileExW rather than ReplaceFileW: ReplaceFileW needs the
/// destination to exist (a first save would need a second path) and it merges attributes and ACLs we do not use; both
/// replace the file in one directory operation on NTFS.
enum WinAtomicWrite {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let code: DWORD
        var description: String { "\(step) failed (Win32 error \(code))" }
    }

    static func write(_ data: Data, to url: URL) throws {
        let target = WinPath.native(url)
        let folder = WinPath.native(url.deletingLastPathComponent())
        let temp = folder + "\\." + url.lastPathComponent + "." + UUID().uuidString.prefix(8) + ".tmp"
        try writeFile(data, atPath: temp)  // CREATE_NEW: a failure here means we created nothing, so nothing to delete
        do {
            try PlatformCompat.atomicWriteFaultForTesting?()
            try replace(temp, with: target)
        } catch {
            _ = temp.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            throw error
        }
    }

    private static func writeFile(_ data: Data, atPath path: String) throws {
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure(step: "create", code: GetLastError()) }
        // Past this point the file is ours: a failed write removes it.
        var complete = false
        defer { CloseHandle(handle); if !complete { _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) } } }
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count {
                var written: DWORD = 0
                let chunk = DWORD(min(raw.count - offset, 1 << 20))
                guard WriteFile(handle, raw.baseAddress!.advanced(by: offset), chunk, &written, nil), written > 0 else {
                    throw Failure(step: "write", code: GetLastError())
                }
                offset += Int(written)
            }
        }
        complete = true
    }

    /// A reader (the antivirus, a second writer finishing its own rename) can hold the target for a moment:
    /// ACCESS_DENIED and SHARING_VIOLATION are retried a few times, 10 ms apart; anything else fails at once.
    private static func replace(_ temp: String, with target: String) throws {
        var code: DWORD = 0
        for attempt in 0..<5 {
            let ok = temp.withCString(encodedAs: UTF16.self) { from in
                target.withCString(encodedAs: UTF16.self) { to in
                    MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING))
                }
            }
            if ok { return }
            code = GetLastError()
            guard code == DWORD(ERROR_ACCESS_DENIED) || code == DWORD(ERROR_SHARING_VIOLATION), attempt < 4 else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure(step: "rename", code: code)
    }
}
#endif
