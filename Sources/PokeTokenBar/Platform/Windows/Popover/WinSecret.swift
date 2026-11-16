#if os(Windows)
import Foundation
import WinSDK

/// The claude.ai session key's file on Windows (stage 7 Task 14, D14, ruling 5): DPAPI, current-user scope.
///
/// The Mac keeps `session-key.json` as plain JSON in an owner-only (0600) file. On Windows 0600 does nothing (swift-foundation
/// maps it onto the read-only attribute only), so the file would just inherit `%LOCALAPPDATA%`'s ACL. Here the same JSON is
/// encrypted with `CryptProtectData` before it is written (`PlatformCompat.writeSecret`) and decrypted when it is read
/// (`PlatformCompat.readSecret`), in the same file, written atomically (`WinAtomicWrite`: a temporary file renamed over it).
///
/// What it protects against: another Windows account on this PC, a copy of the file (a backup, the disk read offline or from
/// another account) — DPAPI's key comes from this account's logon secret. What it does not: any program running as this same
/// user, which can call `CryptUnprotectData` as we do (the entropy below is not a secret), and the key while it is in this
/// process's memory (it lives in Swift strings while the app uses it, as on the Mac).
///
/// A file that does not decrypt (copied from another PC or account, a reset profile, damaged) reads as no key, with one log line
/// that names the file and the Win32 error, never any of its bytes. A plain-JSON file (an earlier Windows build wrote one) is
/// encrypted in place the first time it is read: the encrypted file replaces it in one rename, so the file never goes missing.
/// Every read, migration and write holds one lock: a migration cannot overwrite a key saved at the same moment.
enum WinSecret {
    /// Not a secret: it ties a blob to this app's use of DPAPI. A program that asks DPAPI for the blob with no entropy or with
    /// another one gets nothing, and a blob made for another program is not taken for ours.
    static let entropy = Data("PokeTokenBar/session-key/1".utf8)

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let code: DWORD
        var description: String { "\(step) failed (Win32 error \(code))" }
    }

    /// `DATA_BLOB` (wincrypt.h): a byte count and a pointer. Laid out as C lays it out (checked by a test: 16 bytes, the
    /// pointer at 8).
    struct Blob {
        var cbData: DWORD = 0
        var pbData: UnsafeMutablePointer<UInt8>? = nil
    }

    private typealias ProtectFn = @convention(c) (
        UnsafeMutablePointer<Blob>?, UnsafePointer<UInt16>?, UnsafeMutablePointer<Blob>?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, DWORD, UnsafeMutablePointer<Blob>?) -> Int32
    private typealias UnprotectFn = @convention(c) (
        UnsafeMutablePointer<Blob>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>?, UnsafeMutablePointer<Blob>?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, DWORD, UnsafeMutablePointer<Blob>?) -> Int32

    /// `CRYPTPROTECT_UI_FORBIDDEN`: never a prompt. No `CRYPTPROTECT_LOCAL_MACHINE`: only this Windows account can decrypt.
    private static let uiForbidden: DWORD = 0x1

    // MARK: DPAPI

    /// The encrypted bytes, or nil when DPAPI refused (logged by the caller that needs it).
    static func protect(_ data: Data, entropy: Data = WinSecret.entropy) -> Data? { try? protecting(data, entropy: entropy) }

    /// The plain bytes, or nil when `data` is not a blob this account made with `entropy` (another account's or PC's,
    /// tampered with, or made with another entropy).
    static func unprotect(_ data: Data, entropy: Data = WinSecret.entropy) -> Data? { try? unprotecting(data, entropy: entropy) }

    static func protecting(_ data: Data, entropy: Data) throws -> Data {
        guard let fn = WinDynamic.symbol("crypt32.dll", "CryptProtectData", as: ProtectFn.self) else {
            throw Failure(step: "loading CryptProtectData", code: GetLastError())
        }
        var out = Blob()
        // The plain bytes are passed in place (Swift's own storage): no copy of them is made here.
        let (ok, code): (Int32, DWORD) = data.withUnsafeBytes { plain in
            entropy.withUnsafeBytes { salt in
                var input = Blob(cbData: DWORD(plain.count),
                                 pbData: plain.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: UInt8.self)) })
                var extra = Blob(cbData: DWORD(salt.count),
                                 pbData: salt.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: UInt8.self)) })
                let r = fn(&input, nil, &extra, nil, nil, uiForbidden, &out)
                return (r, GetLastError())
            }
        }
        guard ok != 0, let bytes = out.pbData else { throw Failure(step: "CryptProtectData", code: code) }
        defer { _ = LocalFree(UnsafeMutableRawPointer(bytes)) }
        return Data(bytes: bytes, count: Int(out.cbData))
    }

    static func unprotecting(_ data: Data, entropy: Data) throws -> Data {
        guard let fn = WinDynamic.symbol("crypt32.dll", "CryptUnprotectData", as: UnprotectFn.self) else {
            throw Failure(step: "loading CryptUnprotectData", code: GetLastError())
        }
        var out = Blob()
        let (ok, code): (Int32, DWORD) = data.withUnsafeBytes { blob in
            entropy.withUnsafeBytes { salt in
                var input = Blob(cbData: DWORD(blob.count),
                                 pbData: blob.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: UInt8.self)) })
                var extra = Blob(cbData: DWORD(salt.count),
                                 pbData: salt.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: UInt8.self)) })
                let r = fn(&input, nil, &extra, nil, nil, uiForbidden, &out)
                return (r, GetLastError())
            }
        }
        guard ok != 0, let bytes = out.pbData else { throw Failure(step: "CryptUnprotectData", code: code) }
        defer {
            // DPAPI's buffer holds the plain JSON: zeroed before it goes back to the heap (the C buffer is the one copy this
            // code owns; the returned Data is Swift's, like every String the key passes through, as on the Mac).
            _ = UnsafeMutableRawBufferPointer(start: bytes, count: Int(out.cbData)).initializeMemory(as: UInt8.self, repeating: 0)
            _ = LocalFree(UnsafeMutableRawPointer(bytes))
        }
        return Data(bytes: bytes, count: Int(out.cbData))
    }

    // MARK: the file (PlatformCompat.writeSecret / readSecret on Windows)

    private static let lock = NSLock()
    /// Files already reported as unreadable in this run: one log line each, until a read or a write succeeds again.
    nonisolated(unsafe) private static var reported: Set<String> = []
    /// Every line this type logs also goes here (tests read them; `AppLog` writes nothing under `swift test`).
    nonisolated(unsafe) static var logLineForTesting: ((String) -> Void)?

    /// Encrypts `data` and writes it so a reader sees the old file or the new one, never half of it.
    static func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let blob: Data
        do {
            blob = try protecting(data, entropy: entropy)
        } catch {
            log("secret: \(url.lastPathComponent) was not saved: \(error)")
            throw error
        }
        try WinAtomicWrite.write(blob, to: url)
        reported.remove(url.path)
    }

    /// The decrypted bytes; nil for no file, an empty file (a save in progress) or a file that does not decrypt here.
    static func read(at url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        let name = url.lastPathComponent
        if isPlainJSON(raw) {
            // Written by an earlier Windows build (or by hand): encrypted now, in one rename over the same file.
            do {
                try WinAtomicWrite.write(try protecting(raw, entropy: entropy), to: url)
                log("secret: \(name) was plain text; it is encrypted for this Windows account now")
                reported.remove(url.path)
            } catch {
                logOnce(url, "secret: \(name) is plain text and could not be encrypted (\(error)); it is read as it is")
            }
            return raw
        }
        do {
            let plain = try unprotecting(raw, entropy: entropy)
            reported.remove(url.path)
            return plain
        } catch {
            logOnce(url, "secret: \(name) cannot be decrypted for this Windows account (\(error)); it reads as no key")
            return nil
        }
    }

    /// A plain JSON object: its first non-space byte is `{`. A DPAPI blob starts with its version, 1 (`01 00 00 00`).
    static func isPlainJSON(_ data: Data) -> Bool {
        data.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } == 0x7B
    }

    private static func logOnce(_ url: URL, _ line: String) {
        guard reported.insert(url.path).inserted else { return }
        log(line)
    }

    private static func log(_ line: String) {
        AppLog.write(line)
        logLineForTesting?(line)
    }

    /// For the selftest's and the tests' reports: forget what was reported.
    static func resetReportsForTesting() {
        lock.lock()
        reported = []
        lock.unlock()
    }
}
#endif
