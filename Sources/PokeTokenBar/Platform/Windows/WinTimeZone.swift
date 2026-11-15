#if os(Windows)
import Foundation
import WinSDK

/// The system time zone as Foundation sees it. swift-foundation's Windows `TimeZone.current` maps
/// `TIME_ZONE_INFORMATION.StandardName` through ICU, but `StandardName` is LOCALIZED ("대한민국 표준시" on a Korean PC,
/// "Coordinated Universal Time" for UTC) while ICU wants the English Windows zone id ("Korea Standard Time", "UTC"):
/// the lookup fails and `TimeZone.current` becomes GMT, so "today", the day timer and every day key would be computed in
/// GMT. Foundation reads the `TZ` variable first, so this publishes the IANA name there (the process environment only: the
/// C runtime's own copy, which `localtime` reads, is untouched). The IANA name comes from the OS's own ICU
/// (`icu.dll`, Windows 10 1903+) for the zone's `TimeZoneKeyName`, which is never localized, renamed by `TimeZoneNames` where
/// corelibs' `DateFormatter` would trap on the ICU name.
enum WinTimeZone {
    private typealias WindowsIDFn = @convention(c) (UnsafePointer<UInt16>?, Int32, UnsafePointer<CChar>?,
                                                    UnsafeMutablePointer<UInt16>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32

    /// What this process last put in `TZ` (nil: nothing yet), so a `TZ` the user set themselves is never overwritten.
    nonisolated(unsafe) private(set) static var published: String?

    /// `TimeZoneKeyName` of `GetDynamicTimeZoneInformation`: the English Windows zone id.
    static func windowsKeyName() -> String? {
        var info = DYNAMIC_TIME_ZONE_INFORMATION()
        guard GetDynamicTimeZoneInformation(&info) != TIME_ZONE_ID_INVALID else { return nil }
        let name = withUnsafeBytes(of: info.TimeZoneKeyName) { raw in
            String(decoding: raw.bindMemory(to: UInt16.self).prefix(while: { $0 != 0 }), as: UTF16.self)
        }
        return name.isEmpty ? nil : name
    }

    /// `ucal_getTimeZoneIDForWindowsID` of the OS's ICU; nil for an id it does not know (a localized name, for one).
    static func iana(forWindowsID id: String) -> String? {
        guard let fn = WinDynamic.symbol("icu.dll", "ucal_getTimeZoneIDForWindowsID", as: WindowsIDFn.self) else { return nil }
        let input = Array(id.utf16)
        var out = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = input.withUnsafeBufferPointer { fn($0.baseAddress, Int32($0.count), nil, &out, Int32(out.count), &status) }
        guard status <= 0, length > 0 else { return nil }
        return String(decoding: out.prefix(Int(length)), as: UTF16.self)
    }

    /// Puts the system zone's IANA name in `TZ` unless the user set one. Returns the name, nil when nothing was published.
    /// Call before the first `TimeZone.current` and again before `NSTimeZone.resetSystemTimeZone()` on a time change.
    @discardableResult
    static func publishSystemZone() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let current = env["TZ"], current != published { return nil }  // the user's own TZ wins, as it does in Foundation
        guard let key = windowsKeyName(), let iana = iana(forWindowsID: key) else { return nil }
        let name = TimeZoneNames.foundationSafe(iana)
        PlatformCompat.setEnvironment("TZ", name)
        published = name
        return name
    }
}
#endif
