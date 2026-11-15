#if os(Windows)
import Foundation
import WinSDK

/// Which way a WinHTTP fetch leaves the machine. The precedence is libcurl's, which URLSession used on Windows before:
/// `no_proxy` first, then `<scheme>_proxy`, then `all_proxy` (curl 8.9.1 `lib/url.c` 2033-2110 and 2387-2406; matching in
/// `lib/noproxy.c` 122-260). Windows environment names are case-insensitive, so `NO_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` are
/// the same variables, read from the process environment as libcurl reads them there (`GetEnvironmentVariable`, an empty
/// value counts as unset: `lib/getenv.c`). The explicit environment wins. Without any proxy variable the request follows the
/// Windows proxy settings (the system proxy, a PAC script or WPAD; libcurl ignored those).
enum WinProxyRoute {
    enum Route: Equatable, Sendable {
        /// `no_proxy` matched the host: no proxy at all (libcurl did the same).
        case direct
        /// No proxy variable: whatever Windows is set to (`WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY`).
        case systemProxy
        /// An HTTP proxy from the environment, as `host:port` (libcurl's default port 1080 when none is given, `lib/url.h` 57).
        case namedProxy(String)
        /// A proxy form WinHTTP cannot take the way libcurl would (another scheme, credentials in the URL): URLSession keeps it.
        case urlSession(String)
    }

    static func route(for url: URL, environment: (String) -> String? = environmentValue) -> Route {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return .systemProxy }
        if let list = environment("no_proxy"), noProxyMatches(host: host, list: list) { return .direct }
        guard let raw = environment("\(scheme)_proxy") ?? environment("all_proxy") else { return .systemProxy }
        guard let hostPort = proxyHostPort(raw) else { return .urlSession("a \(scheme) proxy variable WinHTTP cannot use as libcurl would") }
        return .namedProxy(hostPort)
    }

    /// The process environment the way libcurl reads it on Windows: nil when unset or empty.
    static func environmentValue(_ name: String) -> String? {
        let wide = WinStr.w(name)
        var buffer = [UInt16](repeating: 0, count: 256)
        while true {
            let n = Int(GetEnvironmentVariableW(wide, &buffer, DWORD(buffer.count)))
            if n == 0 { return nil }
            if n < buffer.count { return String(decoding: buffer.prefix(n), as: UTF16.self) }
            buffer = [UInt16](repeating: 0, count: n + 1)
        }
    }

    /// `host:port` for WinHTTP from a libcurl proxy value, or nil when libcurl would do something WinHTTP cannot:
    /// a scheme other than http (https, socks4/4a/5/5h), or a user name in it (libcurl would send it as Basic auth).
    static func proxyHostPort(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let separator = text.range(of: "://") {
            guard text[..<separator.lowerBound].lowercased() == "http" else { return nil }
            text = String(text[separator.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        guard !text.isEmpty, !text.contains("@") else { return nil }
        var host = text
        var port = "1080"
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[...close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { port = String(rest.dropFirst()) } else if !rest.isEmpty { return nil }
        } else if let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            port = String(text[text.index(after: colon)...])
        }
        guard !host.isEmpty, let number = Int(port), (1...65535).contains(number) else { return nil }
        return "\(host):\(number)"
    }

    /// libcurl's `Curl_check_noproxy`: `*` alone matches everything; comma-separated entries (blanks around them allowed);
    /// a name matches itself or any name below it (`example.com` matches `www.example.com`, not `nonexample.com`; leading
    /// and trailing dots ignored); an IPv4/IPv6 entry matches the address, with an optional `/bits` prefix length.
    static func noProxyMatches(host rawHost: String, list: String) -> Bool {
        guard !rawHost.isEmpty, !list.isEmpty else { return false }
        if list == "*" { return true }
        enum Kind { case name, v4, v6 }
        var name = rawHost
        var kind = Kind.name
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<close])
            kind = .v6
        } else if name.contains(":") {
            kind = .v6
        } else if ipv4(name) != nil {
            kind = .v4
        } else if name.hasSuffix(".") {
            name.removeLast()
        }
        for part in list.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = part.drop { $0 == " " || $0 == "\t" }
            // libcurl stops at the first blank inside an entry and ends the whole list there.
            let blank = trimmed.firstIndex { $0 == " " || $0 == "\t" }
            var token = String(blank.map { trimmed[..<$0] } ?? trimmed)
            let endsList = blank.map { trimmed[$0...].contains { $0 != " " && $0 != "\t" } } ?? false
            if !token.isEmpty {
                switch kind {
                case .name:
                    if token.hasSuffix(".") { token.removeLast() }
                    if token.hasPrefix(".") { token.removeFirst() }
                    let n = name.lowercased(), t = token.lowercased()
                    if !t.isEmpty, n == t || n.hasSuffix("." + t) { return true }
                case .v4, .v6:
                    var bits = 0
                    if let slash = token.firstIndex(of: "/") {
                        bits = Int(token[token.index(after: slash)...]) ?? -1
                        token = String(token[..<slash])
                    }
                    if kind == .v4 ? cidr4(name, token, bits) : cidr6(name, token, bits) { return true }
                }
            }
            if endsList { break }
        }
        return false
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(String(p)) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    /// `Curl_cidr4_match`: 0 or 32 bits compare the whole address.
    private static func cidr4(_ address: String, _ check: String, _ bits: Int) -> Bool {
        guard let a = ipv4(address), let c = ipv4(check), (0...32).contains(bits) else { return false }
        if bits == 0 || bits == 32 { return a == c }
        let mask = UInt32.max << UInt32(32 - bits)
        return a & mask == c & mask
    }

    /// `Curl_cidr6_match`: 0 or 128 bits compare the whole address.
    private static func cidr6(_ address: String, _ check: String, _ bits: Int) -> Bool {
        guard let a = ipv6(address), let c = ipv6(check), (0...128).contains(bits) else { return false }
        let all = bits == 0 ? 128 : bits
        let whole = all / 8, rest = all % 8
        if a[0..<whole] != c[0..<whole] { return false }
        if rest == 0 { return true }
        let mask = UInt8(0xff) << UInt8(8 - rest)
        return a[whole] & mask == c[whole] & mask
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ok = bytes.withUnsafeMutableBytes { inet_pton(23 /* AF_INET6 */, text, $0.baseAddress) }
        return ok == 1 ? bytes : nil
    }
}
#endif
