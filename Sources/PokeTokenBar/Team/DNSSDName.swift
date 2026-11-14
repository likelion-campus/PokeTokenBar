import Foundation

/// How a team instance is named in DNS-SD. Pure string work shared by every transport: the Mac advertises the bare
/// label (`ptb-<12 hex>`) and the Windows `windns` API speaks full names (`<label>._ptbteam._tcp.local`).
enum DNSSDName {
    static let defaultServiceType = "_ptbteam._tcp"

    /// `ptb-ab12._ptbteam._tcp.local` (with or without the trailing dot, any letter case) gives `ptb-ab12`.
    /// A name of another service, or one with no label in front of the suffix, gives nil.
    static func instanceLabel(fromPTR name: String, serviceType: String = defaultServiceType) -> String? {
        var trimmed = name
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        let suffix = "." + serviceType + ".local"
        guard let range = trimmed.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]),
              range.lowerBound > trimmed.startIndex else { return nil }
        return String(trimmed[..<range.lowerBound])
    }

    static func fullName(instance: String, serviceType: String = defaultServiceType) -> String {
        instance + "." + serviceType + ".local"
    }
}
