#if os(Windows)
import XCTest
import Foundation
import WinSDK
import Crypto
@testable import PokeTokenBar

/// TLS-PSK over real loopback sockets, both ends in this process (non-blocking, driven by polling loops).
final class WindowsTLSTests: XCTestCase {
    private static let wsaStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    private let code = TeamCode(parsing: "PTB-AAAA-BBBB-CCCC")!
    private let otherCode = TeamCode(parsing: "PTB-DDDD-EEEE-FFFF")!
    private var sockets: [SOCKET] = []

    override func setUp() { XCTAssertTrue(Self.wsaStarted) }
    override func tearDown() { for s in sockets { closesocket(s) }; sockets = [] }

    // MARK: socket helpers

    private func setNonBlocking(_ s: SOCKET) {
        var mode: u_long = 1
        ioctlsocket(s, Int32(bitPattern: 0x8004667E), &mode)  // FIONBIO (a macro the importer cannot see)
    }

    private func loopbackAddress(port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.S_un.S_addr = 0x0100_007F  // 127.0.0.1
        return a
    }

    private func listener() -> (socket: SOCKET, port: UInt16) {
        let s = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        XCTAssertNotEqual(s, SOCKET.max)
        sockets.append(s)
        var a = loopbackAddress(port: 0)
        let size = Int32(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, size) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(s, 4), 0)
        var len = size
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return (s, UInt16(bigEndian: a.sin_port))
    }

    /// Blocking connect to 127.0.0.1:port, then non-blocking. nil if nothing listens yet.
    private func connectLoopback(port: UInt16) -> SOCKET? {
        let s = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        var a = loopbackAddress(port: port)
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { closesocket(s); return nil }
        sockets.append(s)
        setNonBlocking(s)
        return s
    }

    private func acceptOne(_ listener: SOCKET, seconds: Double = 15) -> SOCKET? {
        let end = Date().addingTimeInterval(seconds)
        setNonBlocking(listener)
        while Date() < end {
            let c = accept(listener, nil, nil)
            if c != SOCKET.max { sockets.append(c); setNonBlocking(c); return c }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func socketPair() -> (client: SOCKET, server: SOCKET) {
        let l = listener()
        let c = connectLoopback(port: l.port)!
        return (c, acceptOne(l.socket)!)
    }

    private func isTerminal(_ s: WinTLSSession.Step) -> Bool {
        switch s { case .wantRead, .wantWrite: return false; default: return true }
    }

    /// Drives both handshakes until each reaches a terminal step.
    private func handshake(_ a: WinTLSSession, _ b: WinTLSSession) -> (WinTLSSession.Step, WinTLSSession.Step) {
        var sa = a.handshake(), sb = b.handshake()
        for _ in 0..<5000 where !(isTerminal(sa) && isTerminal(sb)) {
            if !isTerminal(sa) { sa = a.handshake() }
            if !isTerminal(sb) { sb = b.handshake() }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return (sa, sb)
    }

    private struct Pair { let client: WinTLSSession; let server: WinTLSSession }

    private func connected(clientCode: TeamCode? = nil) throws -> Pair {
        let (cs, ss) = socketPair()
        let client = WinTLSSession(context: try WinTLSContext(code: clientCode ?? code, role: .client), socket: UInt(cs))
        let server = WinTLSSession(context: try WinTLSContext(code: code, role: .server), socket: UInt(ss))
        let (a, b) = handshake(client, server)
        XCTAssertEqual(a, .done)
        XCTAssertEqual(b, .done)
        return Pair(client: client, server: server)
    }

    private func failureText(_ s: WinTLSSession.Step) -> String? {
        if case .failed(let m) = s { return m }
        return nil
    }

    // MARK: tests

    func testOpenSSLHMACEqualsSwiftCrypto() throws {
        for (c, msg) in [("AAAABBBBCCCC", "poketokenbar.team.psk.v1"), ("", "x"), (String(repeating: "Z", count: 200), "")] {
            let mine = try XCTUnwrap(WinTLS.hmacSHA256(key: Data(c.utf8), message: Data(msg.utf8)))
            let theirs = Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: Data(c.utf8))))
            XCTAssertEqual(mine, theirs)
        }
        let derived = try XCTUnwrap(WinTLS.hmacSHA256(key: Data(code.normalized.utf8), message: Data("poketokenbar.team.psk.v1".utf8)))
        XCTAssertEqual(derived, code.pskKey.withUnsafeBytes { Data($0) })
    }

    func testSameCodeHandshakesWithThePSKSuite() throws {
        let p = try connected()
        XCTAssertEqual(p.client.cipher, "PSK-AES128-GCM-SHA256")
        XCTAssertEqual(p.server.cipher, "PSK-AES128-GCM-SHA256")
        XCTAssertEqual(p.client.version, "TLSv1.2")
        XCTAssertEqual(p.server.version, "TLSv1.2")
        p.client.close(); p.server.close()
    }

    func testDifferentCodeFailsOnBothSides() throws {
        let (cs, ss) = socketPair()
        let client = WinTLSSession(context: try WinTLSContext(code: otherCode, role: .client), socket: UInt(cs))
        let server = WinTLSSession(context: try WinTLSContext(code: code, role: .server), socket: UInt(ss))
        let (a, b) = handshake(client, server)
        let ca = try XCTUnwrap(failureText(a), "client: \(a)"), cb = try XCTUnwrap(failureText(b), "server: \(b)")
        for text in [ca, cb] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(code.normalized) || text.contains(otherCode.normalized))
        }
        XCTAssertNil(client.cipher)
        XCTAssertNil(server.cipher)
    }

    func testWrongIdentityIsRefused() throws {
        let (cs, ss) = socketPair()
        let key = code.pskKey.withUnsafeBytes { Array($0) }
        let client = WinTLSSession(context: try WinTLSContext(key: key, identity: "ptb-team-v2", role: .client), socket: UInt(cs))
        let server = WinTLSSession(context: try WinTLSContext(code: code, role: .server), socket: UInt(ss))
        let (a, b) = handshake(client, server)
        XCTAssertNotNil(failureText(a), "client: \(a)")
        XCTAssertNotNil(failureText(b), "server: \(b)")
    }

    /// Moves `total` bytes from `from` to `to` (interleaved, since neither side can finish alone) and returns what arrived.
    private func transfer(_ payload: Data, from: WinTLSSession, to: WinTLSSession, sawPending: inout Bool) -> Data {
        var sent = 0, got = Data()
        for _ in 0..<200_000 where got.count < payload.count {
            if sent < payload.count {
                let (n, step) = from.write(payload.subdata(in: sent..<payload.count))
                XCTAssertTrue(n > 0 || step == .wantWrite || step == .wantRead, "write: \(step)")
                sent += n
            }
            while true {
                let (d, step) = to.read(max: 4096)
                if let d { got.append(d); if to.pending > 0 { sawPending = true } } else {
                    XCTAssertTrue(step == .wantRead || step == .wantWrite, "read: \(step)")
                    break
                }
            }
            if got.count < payload.count { Thread.sleep(forTimeInterval: 0.0005) }
        }
        return got
    }

    func testABigWriteIsReadBackWholeThroughPending() throws {
        let p = try connected()
        let big = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })  // > 6 TLS records of 16 KB
        var pending = false
        XCTAssertEqual(transfer(big, from: p.client, to: p.server, sawPending: &pending), big)
        XCTAssertTrue(pending, "a 4 KB read of a 16 KB record must leave decrypted bytes pending")
        var pendingBack = false
        XCTAssertEqual(transfer(big, from: p.server, to: p.client, sawPending: &pendingBack), big)
        p.client.close(); p.server.close()
    }

    func testCloseSendsCloseNotify() throws {
        let p = try connected()
        p.client.close()
        var step = WinTLSSession.Step.wantRead
        for _ in 0..<2000 where step == .wantRead {
            step = p.server.read(max: 16).1
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertEqual(step, .closed)
        p.server.close()
        p.server.close()  // idempotent
        XCTAssertEqual(p.server.handshake(), .failed("TLS session closed"))
    }

    // MARK: OpenSSL command line (a third, independent TLS stack)

    private func opensslExecutable() -> URL? {
        var dirs = ["C:/Program Files/Git/usr/bin", "C:/Program Files/Git/mingw64/bin", "C:/Strawberry/c/bin"]
        dirs += (ProcessInfo.processInfo.environment["Path"] ?? "").split(separator: ";").map(String.init)
        for d in dirs {
            let u = URL(fileURLWithPath: d).appendingPathComponent("openssl.exe")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    private func keyHex() -> String { code.pskKey.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }

    private func launch(_ exe: URL, _ args: [String], stdin: Pipe? = nil) throws -> Process {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let stdin { p.standardInput = stdin }
        try p.run()
        return p
    }

    func testInteropWithTheOpenSSLCommandLine() throws {
        guard let exe = opensslExecutable() else { throw XCTSkip("openssl.exe not found") }
        // Our client against `openssl s_server`.
        let free = listener()  // reserve a free port, then release it for s_server
        closesocket(free.socket)
        let server = try launch(exe, ["s_server", "-psk", keyHex(), "-psk_identity", "ptb-team-v1",
                                      "-cipher", "PSK-AES128-GCM-SHA256", "-tls1_2", "-nocert", "-accept", String(free.port)])
        defer { server.terminate() }
        var sock: SOCKET?
        for _ in 0..<100 where sock == nil {
            sock = connectLoopback(port: free.port)
            if sock == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        let s = try XCTUnwrap(sock, "s_server never listened")
        let client = WinTLSSession(context: try WinTLSContext(code: code, role: .client), socket: UInt(s))
        var step = client.handshake()
        for _ in 0..<5000 where !isTerminal(step) { Thread.sleep(forTimeInterval: 0.002); step = client.handshake() }
        XCTAssertEqual(step, .done)
        XCTAssertEqual(client.cipher, "PSK-AES128-GCM-SHA256")
        XCTAssertEqual(client.version, "TLSv1.2")
        XCTAssertEqual(client.write(Data("hello\n".utf8)).written, 6)
        client.close()
    }

    func testOpenSSLCommandLineClientAgainstOurServer() throws {
        guard let exe = opensslExecutable() else { throw XCTSkip("openssl.exe not found") }
        let l = listener()
        let stdin = Pipe()
        let proc = try launch(exe, ["s_client", "-connect", "127.0.0.1:\(l.port)", "-tls1_2", "-cipher", "PSK-AES128-GCM-SHA256",
                                    "-psk", keyHex(), "-psk_identity", "ptb-team-v1", "-quiet"], stdin: stdin)
        defer { proc.terminate() }
        let accepted = try XCTUnwrap(acceptOne(l.socket), "s_client never connected")
        let server = WinTLSSession(context: try WinTLSContext(code: code, role: .server), socket: UInt(accepted))
        var step = server.handshake()
        for _ in 0..<5000 where !isTerminal(step) { Thread.sleep(forTimeInterval: 0.002); step = server.handshake() }
        XCTAssertEqual(step, .done)
        XCTAssertEqual(server.cipher, "PSK-AES128-GCM-SHA256")
        XCTAssertEqual(server.version, "TLSv1.2")
        stdin.fileHandleForWriting.write(Data("ping\n".utf8))
        var got = Data()
        for _ in 0..<5000 where got.count < 5 {
            if let d = server.read(max: 64).0 { got.append(d) } else { Thread.sleep(forTimeInterval: 0.002) }
        }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "ping\n")
        server.close()
    }
}
#endif
