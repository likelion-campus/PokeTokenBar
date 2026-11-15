#if os(Windows)
import Foundation
import WinSDK

/// What the language and region APIs return on this machine, and whether the app's language follows the display
/// language. `--language-probe <out> [--seed-language en]` prints the same facts as lines without starting the app, so CI
/// can run it under a different display language / time zone.
enum WindowsSelftestLanguage {
    static func facts() -> [(String, String)] {
        let env = ProcessInfo.processInfo.environment
        var facts: [(String, String)] = [
            ("Locale.preferredLanguages", Locale.preferredLanguages.description),
            ("Locale.current", Locale.current.identifier),
            ("Locale.autoupdatingCurrent", Locale.autoupdatingCurrent.identifier),
            ("Locale.current.regionCode", Locale.current.region?.identifier ?? "-"),
            ("Calendar.current.firstWeekday", "\(Calendar.current.firstWeekday)"),
            ("TimeZone.current", TimeZone.current.identifier),
            ("env TZ (published)", "\(env["TZ"] ?? "-") (\(WinTimeZone.published ?? "-"))"),
            ("Windows zone key -> IANA", "\(WinTimeZone.windowsKeyName() ?? "-") -> \(WinTimeZone.windowsKeyName().flatMap { WinTimeZone.iana(forWindowsID: $0) } ?? "-")"),
            ("TimeZone.current.offsetMinutes", "\(TimeZone.current.secondsFromGMT() / 60)"),
            ("env LANG", env["LANG"] ?? "-"),
            ("GetUserPreferredUILanguages", WinUILanguage.win32UILanguages().description),
            ("GetUserDefaultLocaleName", WinUILanguage.win32LocaleName() ?? "-"),
            ("GetUserDefaultUILanguage", "0x" + String(GetUserDefaultUILanguage(), radix: 16)),
            ("PlatformCompat.preferredUILanguages", PlatformCompat.preferredUILanguages.description),
            ("AppLanguage.systemDefault", AppLanguage.systemDefault.rawValue),
        ]
        var tz = DYNAMIC_TIME_ZONE_INFORMATION()
        _ = GetDynamicTimeZoneInformation(&tz)
        let key = withUnsafeBytes(of: tz.TimeZoneKeyName) { raw in
            String(decoding: raw.bindMemory(to: UInt16.self).prefix(while: { $0 != 0 }), as: UTF16.self)
        }
        facts.append(("Win32 TimeZoneKeyName", key))
        return facts
    }

    /// The tray menu's titles in `language` (the shared model: the Windows menu is built from it).
    static func trayTitles(_ language: AppLanguage) -> [String] {
        TrayMenuModel.items(l: L(language), todayTokens: 1234, todayCost: nil, login: .off, update: nil)
            .compactMap { $0?.title }
    }

    @MainActor static func checks(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) {
        let all = facts()
        let ui = WinUILanguage.win32UILanguages()
        let expected = AppLanguage.systemDefault(for: PlatformCompat.preferredUILanguages.first)
        let detail = all.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        // The app's saved language may be a user's explicit choice later on, so the pin is on the detection itself:
        // the detected language is the mapping of the first display language (or of the locale name when the list is empty).
        let first = ui.first ?? WinUILanguage.win32LocaleName()
        r.add("language.detect", AppLanguage.systemDefault == AppLanguage.systemDefault(for: first) && expected == AppLanguage.systemDefault,
              "app language=\(app.companion.language.rawValue) detected=\(AppLanguage.systemDefault.rawValue); " + detail)
        var tz = DYNAMIC_TIME_ZONE_INFORMATION()
        let zoneState = GetDynamicTimeZoneInformation(&tz)
        let win32Minutes = -(Int(tz.Bias) + Int(zoneState == TIME_ZONE_ID_DAYLIGHT ? tz.DaylightBias : tz.StandardBias))
        let foundationMinutes = TimeZone.current.secondsFromGMT() / 60
        r.add("timezone.matchesWindows", win32Minutes == foundationMinutes,
              "Windows says UTC\(win32Minutes >= 0 ? "+" : "")\(win32Minutes) min, Foundation TimeZone.current=\(TimeZone.current.identifier) \(foundationMinutes) min; "
              + "TZ published=\(WinTimeZone.published ?? "none") (without it Foundation falls back to GMT on a localized zone name)")
        AppLog.write("language: ui=\(ui) detected=\(AppLanguage.systemDefault.rawValue) app=\(app.companion.language.rawValue)")
    }

    /// `--language-probe <out> [--seed-language en]`: facts, tray strings, and (seeded) the one-time migration.
    @MainActor static func runProbe(_ args: [String]) -> Never {
        var lines = facts().map { "\($0.0)=\($0.1)" }
        lines.append("tray.titles=" + trayTitles(.systemDefault).joined(separator: " | "))
        if let i = args.firstIndex(of: "--seed-language"), i + 1 < args.count {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-language-probe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("companion.json")
            try? Data("{\"language\":\"\(args[i + 1])\"}".utf8).write(to: file)
            let suite = "ptb.selftest.language.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let store = CompanionStore(fileURL: file, defaults: defaults)
            let before = store.language.rawValue
            WinUILanguage.migrateStoredLanguage(companion: store, defaults: defaults)
            lines.append("migration.before=\(before)")
            lines.append("migration.after=\(store.language.rawValue)")
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        if let i = args.firstIndex(of: "--language-probe"), i + 1 < args.count {
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: args[i + 1]))
        }
        WindowsApp.exit(0, .helper)
    }
}
#endif
