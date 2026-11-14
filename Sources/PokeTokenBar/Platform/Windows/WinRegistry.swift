#if os(Windows)
import Foundation
import WinSDK

/// The few registry calls the app makes, all under `HKEY_CURRENT_USER` (never HKLM, never elevated). Every function
/// returns the Win32 status instead of throwing: callers decide what a failure means.
enum WinRegistry {
    /// `HKEY_CURRENT_USER` is `(HKEY)(ULONG_PTR)(LONG)0x80000001`, a sign-extended constant Swift cannot import.
    static var currentUser: HKEY { HKEY(bitPattern: UInt(bitPattern: Int(Int32(bitPattern: 0x8000_0001))))! }

    private static let keyQueryValue: DWORD = 0x0001, keySetValue: DWORD = 0x0002, keyCreateSubKey: DWORD = 0x0004
    private static let regSZ: DWORD = 1, regBinary: DWORD = 3
    private static let fileNotFound: LSTATUS = 2, pathNotFound: LSTATUS = 3

    enum Read<T> {
        case value(T)
        case missing
        case failed(Int32)
    }

    static func string(_ subkey: String, _ name: String) -> Read<String> {
        switch raw(subkey, name) {
        case .value(let (type, bytes)):
            guard type == regSZ else { return .failed(-1) }  // someone else's value of another type: not ours
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            return .value(String(decoding: units.prefix { $0 != 0 }, as: UTF16.self))
        case .missing: return .missing
        case .failed(let code): return .failed(code)
        }
    }

    static func bytes(_ subkey: String, _ name: String) -> Read<[UInt8]> {
        switch raw(subkey, name) {
        case .value(let (_, bytes)): return .value(bytes)
        case .missing: return .missing
        case .failed(let code): return .failed(code)
        }
    }

    /// 0 on success. Creates the key when it is missing.
    static func setString(_ subkey: String, _ name: String, _ value: String) -> Int32 {
        let units = Array(value.utf16) + [0]
        return units.withUnsafeBytes { set(subkey, name, type: regSZ, data: Array($0)) }
    }

    static func setBytes(_ subkey: String, _ name: String, _ data: [UInt8]) -> Int32 {
        set(subkey, name, type: regBinary, data: data)
    }

    /// 0 when the value is gone afterwards (it did not exist, or it was deleted).
    static func deleteValue(_ subkey: String, _ name: String) -> Int32 {
        var key: HKEY?
        let opened = RegOpenKeyExW(currentUser, WinStr.w(subkey), 0, keySetValue, &key)
        if opened == fileNotFound || opened == pathNotFound { return 0 }
        guard opened == 0, let key else { return opened }
        defer { RegCloseKey(key) }
        let status = RegDeleteValueW(key, WinStr.w(name))
        return status == fileNotFound ? 0 : status
    }

    /// The value names in a key (the tests compare them before and after).
    static func valueNames(_ subkey: String) -> [String] {
        var key: HKEY?
        guard RegOpenKeyExW(currentUser, WinStr.w(subkey), 0, keyQueryValue, &key) == 0, let key else { return [] }
        defer { RegCloseKey(key) }
        var names: [String] = []
        var index: DWORD = 0
        while true {
            var buffer = [UInt16](repeating: 0, count: 16_384)
            var length = DWORD(buffer.count)
            if RegEnumValueW(key, index, &buffer, &length, nil, nil, nil, nil) != 0 { break }
            names.append(String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
            index += 1
        }
        return names
    }

    /// Deletes a key and everything below it (the tests' scratch keys).
    @discardableResult static func deleteTree(_ subkey: String) -> Int32 {
        RegDeleteTreeW(currentUser, WinStr.w(subkey))
    }

    private static func raw(_ subkey: String, _ name: String) -> Read<(DWORD, [UInt8])> {
        var key: HKEY?
        let opened = RegOpenKeyExW(currentUser, WinStr.w(subkey), 0, keyQueryValue, &key)
        if opened == fileNotFound || opened == pathNotFound { return .missing }
        guard opened == 0, let key else { return .failed(opened) }
        defer { RegCloseKey(key) }
        var type: DWORD = 0
        var size: DWORD = 0
        let probe = RegQueryValueExW(key, WinStr.w(name), nil, &type, nil, &size)
        if probe == fileNotFound { return .missing }
        guard probe == 0 else { return .failed(probe) }
        var data = [UInt8](repeating: 0, count: Int(size) + 2)
        var capacity = DWORD(data.count)
        let status = RegQueryValueExW(key, WinStr.w(name), nil, &type, &data, &capacity)
        guard status == 0 else { return .failed(status) }
        return .value((type, Array(data.prefix(Int(capacity)))))
    }

    private static func set(_ subkey: String, _ name: String, type: DWORD, data: [UInt8]) -> Int32 {
        var key: HKEY?
        let created = RegCreateKeyExW(currentUser, WinStr.w(subkey), 0, nil, 0, keySetValue | keyCreateSubKey | keyQueryValue,
                                      nil, &key, nil)
        guard created == 0, let key else { return created }
        defer { RegCloseKey(key) }
        return data.withUnsafeBufferPointer {
            RegSetValueExW(key, WinStr.w(name), 0, type, $0.baseAddress, DWORD($0.count))
        }
    }
}
#endif
