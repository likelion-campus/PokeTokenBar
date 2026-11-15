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
        var injectedLanguage: AppLanguage?
        var lines = facts().map { "\($0.0)=\($0.1)" }
        lines.append("tray.titles=" + trayTitles(.systemDefault).joined(separator: " | "))
        // `--inject-ui-language ko-KR`: the whole app-side chain for a display language this runner cannot be switched to
        // (no language pack installed): mapping, tray strings, the first-run hint, and the one-time correction of a saved "en".
        if let i = args.firstIndex(of: "--inject-ui-language"), i + 1 < args.count {
            let tag = args[i + 1]
            let list = WinUILanguage.preferred(.init(uiLanguages: { [tag] }, localeName: { nil }))
            let detected = AppLanguage.systemDefault(for: list.first)
            lines.append("inject.detected=\(detected.rawValue)")
            lines.append("inject.tray.titles=" + trayTitles(detected).joined(separator: " | "))
            lines.append("inject.firstRunHint=" + L(detected).trayFirstRunHint)
            injectedLanguage = detected
        }
        if let i = args.firstIndex(of: "--seed-language"), i + 1 < args.count {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-language-probe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("companion.json")
            try? Data("{\"language\":\"\(args[i + 1])\"}".utf8).write(to: file)
            let suite = "ptb.selftest.language.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let store = CompanionStore(fileURL: file, defaults: defaults)
            let before = store.language.rawValue
            WinUILanguage.migrateStoredLanguage(companion: store, defaults: defaults, detected: injectedLanguage ?? .systemDefault)
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

    /// `--tz-hunt <out>`: runs, one at a time and each logged BEFORE it runs, the time-zone-dependent calls the app makes at
    /// launch, with the zone published as the app does. The last line of `<out>` after a crash names the call.
    @MainActor static func runTimeZoneHunt(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--tz-hunt"), i + 1 < args.count else { WindowsApp.exit(2, .helper) }
        let url = URL(fileURLWithPath: args[i + 1])
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        func step(_ name: String, _ body: () -> String) {
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("start \(name)\n".utf8)); try? h.close()
            }
            let result = body()
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("done  \(name): \(result)\n".utf8)); try? h.close()
            }
        }
        step("TimeZone.current") { "\(TimeZone.current.identifier) \(TimeZone.current.secondsFromGMT())" }
        step("Calendar.current.startOfDay") { "\(Calendar.current.startOfDay(for: Date()))" }
        step("Calendar.current.timeZone") { Calendar.current.timeZone.identifier }
        step("NSTimeZone.default") { NSTimeZone.default.identifier }
        step("DateFormatter(current tz).string") {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }
        step("LocalUsageReader.todayKey") { LocalUsageReader.todayKey() }
        step("LocalUsageReader.startOfMonth") { "\(LocalUsageReader.startOfMonth(Date()))" }
        step("ISO8601DateFormatter") { ISO8601DateFormatter().string(from: Date()) }
        step("DayBoundary.nextLocalMidnight") { "\(DayBoundary.nextLocalMidnight(after: Date(), calendar: .current))" }
        step("WindowsSystemEvents") { let e = WindowsSystemEvents(window: nil); e.shutdown(); return "ok" }
        let suite = "ptb.selftest.tzhunt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        step("UsageStore.init") { _ = UsageStore(defaults: defaults); return "ok" }
        step("CompanionStore.init") {
            _ = CompanionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ptb-tzhunt-\(UUID().uuidString).json"), defaults: defaults)
            return "ok"
        }
        defaults.removePersistentDomain(forName: suite)
        step("end") { "all done" }
        WindowsApp.exit(0, .helper)
    }
}
#endif
