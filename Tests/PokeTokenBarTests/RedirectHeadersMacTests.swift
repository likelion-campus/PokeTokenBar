import XCTest
import Foundation

/// What URLSession on the Mac re-sends when it follows a redirect: the reference for the Windows seam's redirect policy
/// (`WinHTTPFetch`, which follows redirects itself). Two loopback servers (127.0.0.1, two ports; "localhost" names the
/// second as another host) record every request; the request carries the credential headers the app's callers set
/// (`Authorization`, `Cookie`) and plain custom ones. No network beyond loopback.
final class RedirectHeadersMacTests: XCTestCase {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]  // names lowercased
        let body: Data
    }

    /// HTTP/1.1 on 127.0.0.1, one request per connection (`Connection: close`). `/r/<status>?to=<url>` answers that status
    /// with `Location: <url>`; anything else answers 200 "ok". Every request is recorded.
    final class Server: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let lock = NSLock()
        private var log: [Seen] = []

        init?() {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { return nil }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, size) } }
            guard bound == 0, Darwin.listen(s, 16) == 0 else { Darwin.close(s); return nil }
            var length = size
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) } }
            fd = s
            port = UInt16(bigEndian: addr.sin_port)
            Thread { [self] in acceptLoop() }.start()
        }

        func seen(_ path: String) -> [Seen] { lock.lock(); defer { lock.unlock() }; return log.filter { $0.path == path } }
        func reset() { lock.lock(); log = []; lock.unlock() }

        private func acceptLoop() {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                serve(c)
            }
        }

        private func serve(_ c: Int32) {
            defer { Darwin.close(c) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var headEnd: Range<Data.Index>?
            while headEnd == nil {
                let n = Darwin.read(c, &buffer, buffer.count)
                if n <= 0 { return }
                data.append(contentsOf: buffer[0..<n])
                headEnd = data.range(of: Data("\r\n\r\n".utf8))
            }
            guard let end = headEnd else { return }
            let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ").map(String.init)
            guard first.count >= 2 else { return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            var body = Data(data[end.upperBound...])
            let length = Int(headers["content-length"] ?? "") ?? 0
            while body.count < length {
                let n = Darwin.read(c, &buffer, min(buffer.count, length - body.count))
                if n <= 0 { break }
                body.append(contentsOf: buffer[0..<n])
            }
            let target = URLComponents(string: first[1])
            let path = target?.path ?? first[1]
            lock.lock(); log.append(Seen(method: first[0], path: path, headers: headers, body: body)); lock.unlock()
            let answer: String
            if path.hasPrefix("/r/"), let to = target?.queryItems?.first(where: { $0.name == "to" })?.value {
                answer = "HTTP/1.1 \(path.dropFirst(3)) Redirect\r\nLocation: \(to)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                answer = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            }
            _ = answer.withCString { Darwin.write(c, $0, strlen($0)) }
        }
    }

    private static let a = Server()
    private static let b = Server()

    private func servers() throws -> (Server, Server) {
        (try XCTUnwrap(Self.a, "loopback server A"), try XCTUnwrap(Self.b, "loopback server B"))
    }

    /// The app's credential headers (Claude OAuth / Grok / OpenCode Go: Authorization; claude.ai session key and Cursor
    /// usage: Cookie) plus custom headers that carry no secret.
    private func request(_ url: String, method: String = "GET", body: String? = nil) throws -> URLRequest {
        var r = URLRequest(url: try XCTUnwrap(URL(string: url)), timeoutInterval: 10)
        r.httpMethod = method
        r.httpBody = body.map { Data($0.utf8) }
        r.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        r.setValue("sessionKey=fixture", forHTTPHeaderField: "Cookie")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("1", forHTTPHeaderField: "X-Probe")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func redirect(from server: Server, status: Int, to target: String) -> String {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
        return "http://127.0.0.1:\(server.port)/r/\(status)?to=\(encoded)"
    }

    private func cookieless() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }

    private func names(_ seen: Seen?) -> String {
        guard let seen else { return "not reached" }
        return ["authorization", "cookie", "anthropic-beta", "x-probe"].filter { seen.headers[$0] != nil }.joined(separator: ",")
            + " method=\(seen.method) body=\(seen.body.count)B"
    }

    /// Another host (127.0.0.1 -> localhost, other port too): URLSession follows; it drops `Authorization` and re-sends an
    /// explicit `Cookie` and the custom headers, on the shared session and on a cookie-less ephemeral one alike.
    func testACrossHostRedirectDropsAuthorizationButReSendsTheCookie() async throws {
        let (a, b) = try servers()
        for (label, session) in [("shared", URLSession.shared), ("ephemeral, no cookies", cookieless())] {
            b.reset()
            let (_, response) = try await session.data(for: try request(redirect(from: a, status: 302, to: "http://localhost:\(b.port)/echo")))
            let hop = b.seen("/echo").last
            print("MAC REDIRECT 302 cross-host (\(label)): \(names(hop))")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, label)
            XCTAssertEqual(response.url?.host, "localhost", label)
            XCTAssertNotNil(hop, label)
            XCTAssertNil(hop?.headers["authorization"], label)
            XCTAssertEqual(hop?.headers["cookie"], "sessionKey=fixture", label)
            XCTAssertEqual(hop?.headers["x-probe"], "1", label)
            XCTAssertEqual(hop?.headers["anthropic-beta"], "oauth-2025-04-20", label)
        }
    }

    /// Same host on another port, and the same origin: the same as across hosts (`Authorization` dropped even there).
    func testSameHostRedirectsAlsoDropAuthorization() async throws {
        let (a, b) = try servers()
        a.reset(); b.reset()
        _ = try await URLSession.shared.data(for: try request(redirect(from: a, status: 302, to: "http://127.0.0.1:\(b.port)/echo")))
        let otherPort = b.seen("/echo").last
        _ = try await URLSession.shared.data(for: try request(redirect(from: a, status: 302, to: "/echo")))
        let sameOrigin = a.seen("/echo").last
        print("MAC REDIRECT 302 other port: \(names(otherPort)); same origin: \(names(sameOrigin))")
        XCTAssertNotNil(otherPort)
        XCTAssertNotNil(sameOrigin)
        XCTAssertNil(otherPort?.headers["authorization"])
        XCTAssertNil(sameOrigin?.headers["authorization"])
        XCTAssertEqual(otherPort?.headers["cookie"], "sessionKey=fixture")
        XCTAssertEqual(sameOrigin?.headers["cookie"], "sessionKey=fixture")
    }

    /// A 307 keeps the method and the body, also to another host (without `Authorization`); a 303 turns a POST into a GET
    /// without the body.
    func testA307KeepsMethodAndBodyAndA303BecomesGet() async throws {
        let (a, b) = try servers()
        b.reset()
        let payload = #"{"grant_type":"refresh_token"}"#
        _ = try await URLSession.shared.data(for: try request(redirect(from: a, status: 307, to: "http://localhost:\(b.port)/echo"),
                                                              method: "POST", body: payload))
        let kept = b.seen("/echo").last
        a.reset()
        _ = try await URLSession.shared.data(for: try request(redirect(from: a, status: 303, to: "/echo"), method: "POST", body: payload))
        let turned = a.seen("/echo").last
        print("MAC REDIRECT 307 cross-host POST: \(names(kept)); 303 POST: \(names(turned))")
        XCTAssertEqual(kept?.method, "POST")
        XCTAssertEqual(kept.map { String(decoding: $0.body, as: UTF8.self) }, payload)
        XCTAssertNil(kept?.headers["authorization"])
        XCTAssertEqual(kept?.headers["cookie"], "sessionKey=fixture")
        XCTAssertEqual(turned?.method, "GET")
        XCTAssertEqual(turned?.body.count, 0)
    }
}
