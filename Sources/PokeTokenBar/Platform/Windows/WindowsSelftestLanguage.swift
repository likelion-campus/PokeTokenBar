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
        regionCheck(r)
    }

    /// `locale.region` (stage 7, D11): the region seams against Windows' own answer. The grouping of 1234567 through
    /// `PlatformCompat.regionLocale` must be how `GetNumberFormatEx` writes it (its decimals cut), and the first weekday
    /// must be `LOCALE_IFIRSTDAYOFWEEK` converted, whatever corelibs' `en_001` says.
    @MainActor static func regionCheck(_ r: WindowsSelftest.Recorder) {
        let facts = regionFacts()
        let value = { (key: String) in facts.first { $0.0 == key }?.1 ?? "-" }
        let grouped = value("region.grouped")
        let windows = value("region.win32.numberInteger")
        let weekday = value("region.firstWeekday")
        let expectedWeekday = RegionFormat.firstWeekday(windowsText: WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_IFIRSTDAYOFWEEK)))
        r.add("locale.region", grouped == windows && weekday == expectedWeekday.map(String.init),
              facts.map { "\($0.0)=\($0.1)" }.joined(separator: "; "))
    }

    /// The region seams and the Win32 values they come from, escaped for a log line (`FormatterProbe.visible`).
    static func regionFacts() -> [(String, String)] {
        let decimal = WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_SDECIMAL)) ?? "."
        let number = WinUILanguage.win32NumberFormat("1234567") ?? "-"
        let integer = number.components(separatedBy: decimal).first ?? number
        return [
            ("region.win32.localeName", WinUILanguage.win32LocaleName() ?? "-"),
            ("region.locale", PlatformCompat.regionLocale.identifier),
            ("region.win32.IFIRSTDAYOFWEEK", WinUILanguage.win32LocaleInfo(LCTYPE(LOCALE_IFIRSTDAYOFWEEK)) ?? "-"),
            ("region.firstWeekday", "\(PlatformCompat.firstWeekday)"),
            ("region.foundation.firstWeekday", "\(Calendar.current.firstWeekday)"),
            ("region.calendar.firstWeekday", "\(PlatformCompat.regionCalendar(timeZone: .current).firstWeekday)"),
            ("region.grouped", TokenFormatter.grouped(1_234_567, locale: PlatformCompat.regionLocale)),
            ("region.foundation.grouped", TokenFormatter.grouped(1_234_567)),
            ("region.win32.number", number),
            ("region.win32.numberInteger", integer),
        ].map { ($0.0, FormatterProbe.visible($0.1)) }
    }

    /// `--language-probe <out> [--seed-language en] [--inject-ui-language ko-KR] [--formatter-probe] [--formatter-trap]`:
    /// facts, tray strings, the region seams, (seeded) the one-time migration, and (opt-in) the formatter outputs.
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
        lines += regionFacts().map { "\($0.0)=\($0.1)" }
        // `--formatter-probe`: what the popover's date, duration and number texts would be in the app language that
        // display language maps to (stage 7, R4). Opt-in, so a formatter that traps cannot take the language checks down.
        if args.contains("--formatter-probe") {
            let language = injectedLanguage ?? .systemDefault
            lines.append("format.language=\(language.rawValue)")
            lines += FormatterProbe.lines(language: language).map { "format.\($0.0)=\($0.1)" }
            lines += FormatterProbe.regionLines().map { "format.\($0.0)=\($0.1)" }
        }
        let out = args.firstIndex(of: "--language-probe").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        // `--formatter-trap`: write what we have, then call DateComponentsFormatter, which corelibs leaves `NSUnsupported()`.
        // The last line says whether this process survived it.
        if args.contains("--formatter-trap"), let out {
            try? Data((lines.joined(separator: "\n") + "\ntrap.start=DateComponentsFormatter\n").utf8).write(to: out)
            let value = FormatterProbe.dateComponentsAbbreviated(7505, language: injectedLanguage ?? .en)
            lines.append("trap.start=DateComponentsFormatter")
            lines.append("trap.survived=DateComponentsFormatter returned \(value)")
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

    /// `--tz-hunt <out> [--from N]`: runs, one at a time and each logged BEFORE it runs, the time-zone-dependent calls the
    /// app makes (and DateFormatter with several zone spellings), skipping the first N. The last "start" line of `<out>`
    /// after a crash names the call; the CI script restarts with `--from` past it until every step ran.
    @MainActor static func runTimeZoneHunt(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--tz-hunt"), i + 1 < args.count else { WindowsApp.exit(2, .helper) }
        let url = URL(fileURLWithPath: args[i + 1])
        let from = args.firstIndex(of: "--from").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
        if from == 0 { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        func formatted(_ zone: TimeZone?) -> String {
            guard let zone else { return "no such zone" }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = zone; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let suite = "ptb.selftest.tzhunt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let steps: [(String, () -> String)] = [
            ("TimeZone.current", { "\(TimeZone.current.identifier) \(TimeZone.current.secondsFromGMT())" }),
            ("Calendar.current.startOfDay", { "\(Calendar.current.startOfDay(for: Date()))" }),
            ("DateFormatter GMT", { formatted(TimeZone(identifier: "GMT")) }),
            ("DateFormatter GMT+0900", { formatted(TimeZone(identifier: "GMT+0900")) }),
            ("DateFormatter secondsFromGMT 32400", { formatted(TimeZone(secondsFromGMT: 32400)) }),
            ("DateFormatter Asia/Seoul", { formatted(TimeZone(identifier: "Asia/Seoul")) }),
            ("DateFormatter GMT-1100", { formatted(TimeZone(identifier: "GMT-1100")) }),
            ("DateFormatter UTC", { formatted(TimeZone(identifier: "UTC")) }),
            ("DateFormatter TimeZone.current", { formatted(.current) }),
            ("LocalUsageReader.todayKey", { LocalUsageReader.todayKey() }),
            ("LocalUsageReader.startOfMonth", { "\(LocalUsageReader.startOfMonth(Date()))" }),
            ("ISO8601DateFormatter", { ISO8601DateFormatter().string(from: Date()) }),
            ("DayBoundary.nextLocalMidnight", { "\(DayBoundary.nextLocalMidnight(after: Date(), calendar: .current))" }),
            ("WindowsSystemEvents", { let e = WindowsSystemEvents(window: nil); e.shutdown(); return "ok" }),
            ("UsageStore.init", { _ = UsageStore(defaults: defaults); return "ok" }),
            ("CompanionStore.init", {
                _ = CompanionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ptb-tzhunt-\(UUID().uuidString).json"), defaults: defaults)
                return "ok"
            }),
        ]
        func append(_ text: String) {
            if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((text + "\n").utf8)); try? h.close() }
        }
        if from == 0 { append("steps=\(steps.count)") }
        for (n, step) in steps.enumerated() where n >= from {
            append("start \(n) \(step.0)")
            let result = step.1()
            append("done  \(n) \(step.0): \(result)")
        }
        defaults.removePersistentDomain(forName: suite)
        append("end")
        WindowsApp.exit(0, .helper)
    }
}
#endif
