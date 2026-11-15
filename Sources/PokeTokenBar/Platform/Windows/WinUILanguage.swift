#if os(Windows)
import Foundation
import WinSDK

/// The user's display languages from Win32. `Locale.preferredLanguages` is empty on Windows (see
/// `PlatformCompat.preferredUILanguages`).
enum WinUILanguage {
    struct APIs {
        var uiLanguages: () -> [String]
        var localeName: () -> String?
        static let live = APIs(uiLanguages: { win32UILanguages() }, localeName: { win32LocaleName() })
    }

    static func preferred(_ apis: APIs = .live) -> [String] {
        UILanguages.resolve(ui: apis.uiLanguages(), localeName: apis.localeName())
    }

    /// `GetUserPreferredUILanguages(MUI_LANGUAGE_NAME)`: the display-language list in order, e.g. `["ko-KR", "en-US"]`.
    static func win32UILanguages() -> [String] {
        var count: ULONG = 0, length: ULONG = 0
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &length), length > 0 else { return [] }
        var buffer = [WCHAR](repeating: 0, count: Int(length))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &buffer, &length) else { return [] }
        return multiString(buffer)
    }

    /// `GetUserDefaultLocaleName`: the regional-format locale ("ko-KR"), not the display language.
    static func win32LocaleName() -> String? {
        var buffer = [WCHAR](repeating: 0, count: Int(LOCALE_NAME_MAX_LENGTH))
        let n = GetUserDefaultLocaleName(&buffer, Int32(buffer.count))
        guard n > 1 else { return nil }
        return String(decoding: buffer.prefix(Int(n) - 1), as: UTF16.self)
    }

    /// A double-NUL-terminated list of UTF-16 strings.
    static func multiString(_ units: [UInt16]) -> [String] {
        var out: [String] = []
        var current: [UInt16] = []
        for unit in units {
            if unit == 0 {
                if current.isEmpty { break }  // the second NUL ends the list
                out.append(String(decoding: current, as: UTF16.self))
                current = []
            } else {
                current.append(unit)
            }
        }
        if !current.isEmpty { out.append(String(decoding: current, as: UTF16.self)) }
        return out
    }

    static let migrationKey = "windows.languageDetectionMigrated"

    /// Once per install: an "en" saved before Windows could detect the language (nobody chose it) becomes the detected
    /// language. See `UILanguages.migratedLanguage`. Runs before anything reads `companion.language`.
    @MainActor static func migrateStoredLanguage(companion: CompanionStore, defaults: UserDefaults,
                                                 detected: AppLanguage = .systemDefault) {
        let done = defaults.bool(forKey: migrationKey)
        defaults.set(true, forKey: migrationKey)
        guard let language = UILanguages.migratedLanguage(stored: companion.language, detected: detected, alreadyMigrated: done) else { return }
        companion.setLanguage(language)
        AppLog.write("language: saved \"en\" was a default, not a choice; now \(language.rawValue) (display language \(preferred().first ?? "-"))")
    }
}
#endif
