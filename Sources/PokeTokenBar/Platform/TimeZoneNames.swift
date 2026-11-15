import Foundation

/// Pure naming rule for the zone the Windows app hands to Foundation (see `WinTimeZone`).
enum TimeZoneNames {
    /// swift-corelibs' `DateFormatter` traps on the "Etc/..." names ICU returns for the Windows zones UTC and "UTC-11" ...
    /// "UTC+13" (CI: `DateFormatter` with `Etc/UTC` crashes, `UTC`, `GMT+0900` and `Asia/Seoul` work). "Etc/UTC" becomes "UTC";
    /// "Etc/GMT+11" (POSIX sign: UTC-11) becomes "GMT-1100". Any other name is kept.
    static func foundationSafe(_ iana: String) -> String {
        guard iana.hasPrefix("Etc/") else { return iana }
        let rest = iana.dropFirst(4)
        if ["UTC", "UCT", "GMT", "Universal", "Zulu", "Greenwich", "GMT0", "GMT+0", "GMT-0"].contains(String(rest)) { return "UTC" }
        guard rest.hasPrefix("GMT"), let sign = rest.dropFirst(3).first, sign == "+" || sign == "-",
              let hours = Int(rest.dropFirst(4)), (1...14).contains(hours) else { return iana }
        return String(format: "GMT%@%02d00", sign == "+" ? "-" : "+", hours)  // Etc/GMT+N is N hours BEHIND UTC
    }
}
