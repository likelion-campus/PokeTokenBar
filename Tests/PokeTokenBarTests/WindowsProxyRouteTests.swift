#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// `WinProxyRoute` keeps libcurl's proxy variables and their precedence (curl 8.9.1 `url.c` detect_proxy, `noproxy.c`).
final class WindowsProxyRouteTests: XCTestCase {
    private func route(_ url: String, _ env: [String: String]) throws -> WinProxyRoute.Route {
        WinProxyRoute.route(for: try XCTUnwrap(URL(string: url))) { env[$0] }
    }

    func testPrecedenceIsLibcurls() throws {
        XCTAssertEqual(try route("https://api.anthropic.com/x", [:]), .systemProxy, "no variable: the Windows settings")
        XCTAssertEqual(try route("https://a.example/x", ["https_proxy": "http://p:3128"]), .namedProxy("p:3128"))
        XCTAssertEqual(try route("http://a.example/x", ["https_proxy": "http://p:3128"]), .systemProxy, "http reads http_proxy only")
        XCTAssertEqual(try route("http://a.example/x", ["http_proxy": "p:8080"]), .namedProxy("p:8080"))
        XCTAssertEqual(try route("https://a.example/x", ["all_proxy": "p"]), .namedProxy("p:1080"), "all_proxy, libcurl's port 1080")
        XCTAssertEqual(try route("https://a.example/x", ["https_proxy": "http://s:1", "all_proxy": "http://a:2"]), .namedProxy("s:1"))
        XCTAssertEqual(try route("https://a.example/x", ["https_proxy": "http://s:1", "no_proxy": "example"]), .direct)
        XCTAssertEqual(try route("https://a.example/x", ["no_proxy": "a.example"]), .direct, "no_proxy alone: no proxy, as libcurl")
        XCTAssertEqual(try route("https://a.example/x", ["https_proxy": "socks5h://s:1080"]), .urlSession("a https proxy variable WinHTTP cannot use as libcurl would"))
    }

    func testProxyValues() {
        let cases: [(String, String?)] = [
            ("http://proxy:8080", "proxy:8080"), ("proxy:3128", "proxy:3128"), ("proxy", "proxy:1080"), ("http://proxy/", "proxy:1080"),
            (" HTTP://Proxy:1 ", "Proxy:1"), ("[::1]:8080", "[::1]:8080"), ("http://[::1]", "[::1]:1080"),
            ("https://proxy:443", nil), ("socks5://p:1080", nil), ("socks4a://p", nil), ("http://user:pass@proxy:8080", nil),
            ("proxy:0", nil), ("proxy:99999", nil), ("proxy:abc", nil), ("", nil), ("http://", nil), ("[::1", nil),
        ]
        for (value, expected) in cases { XCTAssertEqual(WinProxyRoute.proxyHostPort(value), expected, value) }
    }

    func testNoProxyMatchingIsLibcurls() {
        let yes: [(String, String)] = [
            ("example.com", "example.com"), ("www.example.com", "example.com"), ("www.example.com", ".example.com"),
            ("www.example.com.", "example.com"), ("WWW.Example.COM", "example.com."), ("anything", "*"),
            ("api.anthropic.com", "a.example, b.example ,anthropic.com"), ("api.anthropic.com", "x,,anthropic.com"),
            ("10.1.2.3", "10.0.0.0/8"), ("10.1.2.3", "10.1.2.3"), ("192.168.1.5", "192.168.0.0/16"), ("127.0.0.1", "127.0.0.1/32"),
            ("::1", "::1"), ("fe80::1", "fe80::/10"), ("[2001:db8::5]", "2001:db8::/32"),
        ]
        let no: [(String, String)] = [
            ("nonexample.com", "example.com"), ("example.com", "www.example.com"), ("api.anthropic.com", "a.example b.example,anthropic.com"),
            ("api.anthropic.com", " *"), ("10.1.2.4", "10.1.2.3"), ("11.1.2.3", "10.0.0.0/8"), ("2001:db9::1", "2001:db8::/32"),
            ("10.1.2.3", "10.0.0.0/40"), ("example.com", ""),
        ]
        for (host, list) in yes { XCTAssertTrue(WinProxyRoute.noProxyMatches(host: host, list: list), "\(host) in [\(list)]") }
        for (host, list) in no { XCTAssertFalse(WinProxyRoute.noProxyMatches(host: host, list: list), "\(host) not in [\(list)]") }
    }

    /// The process environment as libcurl reads it on Windows: case-insensitive names, an empty value is unset.
    func testTheEnvironmentIsReadAsLibcurlReadsIt() {
        PlatformCompat.setEnvironment("Ptb_Proxy_Probe", "http://p:1")
        defer { PlatformCompat.setEnvironment("Ptb_Proxy_Probe", nil) }
        XCTAssertEqual(WinProxyRoute.environmentValue("PTB_PROXY_PROBE"), "http://p:1")
        PlatformCompat.setEnvironment("Ptb_Proxy_Probe", "")
        XCTAssertNil(WinProxyRoute.environmentValue("ptb_proxy_probe"))
        let long = String(repeating: "x", count: 700)
        PlatformCompat.setEnvironment("Ptb_Proxy_Probe", long)
        XCTAssertEqual(WinProxyRoute.environmentValue("ptb_proxy_probe"), long, "longer than the first buffer")
    }
}
#endif
