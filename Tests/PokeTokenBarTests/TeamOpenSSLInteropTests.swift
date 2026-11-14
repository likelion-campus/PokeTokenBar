import XCTest
import Network
@testable import PokeTokenBar

/// The Mac's TLS-PSK (Network.framework with `BonjourTeamTransport.parameters`) against the OpenSSL command line set up
/// exactly like the Windows side (`Sources/CTeamTLS/CTeamTLS.c`): TLS 1.2 only, `PSK-AES128-GCM-SHA256`, identity
/// `ptb-team-v1`, key `TeamCode.pskKey`, no session tickets, no renegotiation, no session cache. Loopback only: the
/// transport does not advertise and nothing leaves 127.0.0.1. `scripts/team-interop-check.sh` runs this suite.
///
/// Lines starting `INTEROP` are the evidence (the script prints them). When the handshake fails with the Windows
/// options, the test runs again with one option removed at a time and names the option that breaks it.
/// Skipped when no OpenSSL 3 command line is found (`PTB_OPENSSL`, Homebrew's, `/usr/local/bin/openssl`).
@MainActor
final class TeamOpenSSLInteropTests: XCTestCase {
    private static let code = TeamCode(parsing: "PTB-AAAA-BBBB-CCCC")!

    private static var pskHex: String { code.pskKey.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }

    /// What CTeamTLS.c sets beyond TLS 1.2 + the one PSK suite: `SSL_OP_NO_TICKET`, `SSL_OP_NO_RENEGOTIATION`,
    /// and (server) `SSL_SESS_CACHE_OFF`. The client keeps no session (no `-sess_in`/`-reconnect`).
    static let clientHardening = ["-no_ticket", "-no_renegotiation"]
    static let serverHardening = ["-no_ticket", "-no_renegotiation", "-no_cache"]

    private static func openssl() throws -> String {
        let env = ProcessInfo.processInfo.environment["PTB_OPENSSL"]
        for path in [env, "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"].compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: path) {
            let version = run(path, ["version"]).output
            if version.hasPrefix("OpenSSL 3") { return path }
        }
        throw XCTSkip("no OpenSSL 3 command line (set PTB_OPENSSL); the system LibreSSL lacks the PSK options")
    }

    // MARK: - OpenSSL child process

    private final class Child: @unchecked Sendable {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private let lock = NSLock()
        private var bytes = Data()

        init(_ path: String, _ arguments: [String]) throws {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock(); self.bytes.append(d); self.lock.unlock()
            }
            try process.run()
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        var text: String { String(decoding: data, as: UTF8.self) }
        func write(_ d: Data) { try? input.fileHandleForWriting.write(contentsOf: d) }
        /// EOF on stdin: s_client sends close_notify and exits, which flushes its stdio-buffered log.
        func closeInput() { try? input.fileHandleForWriting.close() }
        func stop() { if process.isRunning { process.terminate() } }
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func waitExit(_ child: Child, _ seconds: TimeInterval) async -> Bool {
        await contractWaitUntil(seconds) { !child.process.isRunning }
    }

    private static func freePort() throws -> UInt16 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(s) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, length) == 0 && Darwin.getsockname(s, $0, &length) == 0 }
        }
        guard bound else { throw XCTSkip("no free loopback port") }
        return UInt16(bigEndian: a.sin_port)
    }

    /// The value of the first line starting with `name`: after its last colon, or after the name when it has none
    /// (`Protocol  : TLSv1.2`, `Protocol: TLSv1.2`, `CIPHER is PSK-AES128-GCM-SHA256`).
    private static func field(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(name) else { continue }
            let rest = t.dropFirst(name.count)
            let value = rest.contains(":") ? rest[rest.index(after: rest.lastIndex(of: ":")!)...] : rest
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static let macFrame = TeamMessage.emote(TeamEmote(kind: .heart, targetMemberID: nil))

    // MARK: - openssl s_client -> the Mac listener

    private struct Outcome {
        var ready = false
        var macGot: [TeamMessage] = []
        var log = ""
        var openSSLGotMacFrame: Bool { log.contains(#""emote""#) }
    }

    private func clientRun(_ openssl: String, options: [String]) async throws -> Outcome {
        let t = BonjourTeamTransport(advertise: false)
        var peer: TeamPeerID?
        var outcome = Outcome()
        t.onPeerConnected = { id, _ in peer = id }
        t.onMessage = { _, m in outcome.macGot.append(m) }
        t.start(code: Self.code)
        defer { t.stop() }
        let listening = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(listening, "the Mac listener did not start")
        let port = try XCTUnwrap(t.listenerPort?.rawValue)
        let client = try Child(openssl, ["s_client", "-connect", "127.0.0.1:\(port)", "-tls1_2",
                                         "-cipher", "PSK-AES128-GCM-SHA256", "-psk", Self.pskHex,
                                         "-psk_identity", "ptb-team-v1", "-msg"] + options)
        defer { client.stop() }
        outcome.ready = await contractWaitUntil(10) { peer != nil }
        if outcome.ready, let peer {
            t.send(Self.macFrame, to: peer)
            client.write(try TeamWire.encode(.profileRequest))
            _ = await contractWaitUntil(5) { !outcome.macGot.isEmpty }
            _ = await contractWaitUntil(2) { client.text.contains(#""emote""#) }
        }
        client.closeInput()
        _ = await waitExit(client, 5)
        outcome.log = client.text
        return outcome
    }

    func testOpenSSLClientWithTheWindowsOptionsReachesTheMacListener() async throws {
        let openssl = try Self.openssl()
        let full = try await clientRun(openssl, options: Self.clientHardening)
        let log = full.log
        let proto = Self.field("Protocol", in: log) ?? "?", cipher = Self.field("Cipher", in: log) ?? "?"
        print("INTEROP s_client(\(Self.clientHardening.joined(separator: " "))) -> Mac listener: ready=\(full.ready) "
            + "protocol=\(proto) cipher=\(cipher) mac_got=\(full.macGot.count) openssl_got_mac_frame=\(full.openSSLGotMacFrame) "
            + "server_hello=\(log.contains("ServerHello")) new_session_ticket=\(log.contains("NewSessionTicket"))")
        guard full.ready else {
            try await bisectClient(openssl)
            XCTFail("s_client with the Windows options did not reach the Mac listener:\n\(log)")
            return
        }
        XCTAssertEqual(proto, "TLSv1.2", log)
        XCTAssertEqual(cipher, "PSK-AES128-GCM-SHA256", log)
        XCTAssertEqual(full.macGot, [.profileRequest], "the Mac received the frame OpenSSL sent")
        XCTAssertTrue(full.openSSLGotMacFrame, "OpenSSL received the Mac's frame:\n\(log)")
        XCTAssertTrue(log.contains("ServerHello"))
        XCTAssertFalse(log.contains("NewSessionTicket"), "no ticket is issued to a client that refuses them")
    }

    private func bisectClient(_ openssl: String) async throws {
        for drop in Self.clientHardening {
            let r = try await clientRun(openssl, options: Self.clientHardening.filter { $0 != drop })
            print("INTEROP bisect s_client without \(drop): ready=\(r.ready)")
        }
        let bare = try await clientRun(openssl, options: [])
        print("INTEROP bisect s_client with none of the options: ready=\(bare.ready)")
    }

    // MARK: - the Mac transport -> openssl s_server

    private func serverRun(_ openssl: String, options: [String]) async throws -> Outcome {
        let port = try Self.freePort()
        let server = try Child(openssl, ["s_server", "-accept", "127.0.0.1:\(port)", "-tls1_2", "-nocert",
                                         "-cipher", "PSK-AES128-GCM-SHA256", "-psk", Self.pskHex,
                                         "-psk_identity", "ptb-team-v1", "-naccept", "1", "-msg"] + options)
        defer { server.stop() }
        _ = await contractWaitUntil(5) { server.text.contains("ACCEPT") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let t = BonjourTeamTransport(advertise: false)
        var peer: (TeamPeerID, Bool)?
        var outcome = Outcome()
        t.onPeerConnected = { peer = ($0, $1) }
        t.onMessage = { _, m in outcome.macGot.append(m) }
        t.start(code: Self.code)
        t.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        outcome.ready = await contractWaitUntil(10) { peer != nil }
        if outcome.ready, let peer {
            XCTAssertTrue(peer.1, "the Mac dialled")
            t.send(Self.macFrame, to: peer.0)
            server.write(try TeamWire.encode(.profileRequest))
            _ = await contractWaitUntil(5) { !outcome.macGot.isEmpty }
            _ = await contractWaitUntil(2) { server.text.contains(#""emote""#) }
        }
        t.stop()   // ends the one connection; -naccept 1 then exits and flushes its log
        _ = await waitExit(server, 5)
        outcome.log = server.text
        return outcome
    }

    func testTheMacTransportReachesOpenSSLServerWithTheWindowsOptions() async throws {
        let openssl = try Self.openssl()
        let full = try await serverRun(openssl, options: Self.serverHardening)
        let log = full.log
        let cipher = Self.field("CIPHER is", in: log) ?? "?"
        // s_server prints no version line; its -msg log names the record version of the ServerHello it sent.
        let version = log.contains(">>> TLS 1.2, Handshake") && log.contains("], ServerHello\n") ? "TLSv1.2" : "?"
        print("INTEROP Mac dial -> s_server(\(Self.serverHardening.joined(separator: " "))): ready=\(full.ready) "
            + "protocol=\(version) cipher=\(cipher) mac_got=\(full.macGot.count) openssl_got_mac_frame=\(full.openSSLGotMacFrame) "
            + "new_session_ticket=\(log.contains("NewSessionTicket")) renegotiation_disabled=\(log.contains("Renegotiation is DISABLED"))")
        guard full.ready else {
            try await bisectServer(openssl)
            XCTFail("the Mac transport did not reach s_server with the Windows options:\n\(log)")
            return
        }
        XCTAssertEqual(cipher, "PSK-AES128-GCM-SHA256", log)
        XCTAssertEqual(version, "TLSv1.2", log)
        XCTAssertEqual(full.macGot, [.profileRequest], "the Mac received the frame OpenSSL sent")
        XCTAssertTrue(full.openSSLGotMacFrame, "OpenSSL received the Mac's frame:\n\(log)")
        XCTAssertFalse(log.contains("NewSessionTicket"), "the server issues no ticket")
        XCTAssertTrue(log.contains("Renegotiation is DISABLED"), "s_server ran with -no_renegotiation")
    }

    private func bisectServer(_ openssl: String) async throws {
        for drop in Self.serverHardening {
            let r = try await serverRun(openssl, options: Self.serverHardening.filter { $0 != drop })
            print("INTEROP bisect s_server without \(drop): ready=\(r.ready)")
        }
        let bare = try await serverRun(openssl, options: [])
        print("INTEROP bisect s_server with none of the options: ready=\(bare.ready)")
    }

    // MARK: - the key fingerprint

    /// `scripts/team-interop-check.sh --fingerprint` (OpenSSL's HMAC) prints what `TeamCode.keyFingerprint` (and so the
    /// Windows probe) prints, for every spelling of a code that `TeamCode(parsing:)` accepts.
    func testTheScriptFingerprintIsTheProbeFingerprint() throws {
        let openssl = try Self.openssl()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/team-interop-check.sh").path
        for spelling in ["PTB-AAAA-BBBB-CCCC", "aaaabbbbcccc", " ptb aaaa-bbbb cccc \n"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, "--fingerprint"]
            p.environment = ["PTB_OPENSSL": openssl, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            try p.run()
            try input.fileHandleForWriting.write(contentsOf: Data(spelling.utf8))
            try input.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, text)
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "key_fingerprint=\(Self.code.keyFingerprint)", spelling)
            XCTAssertFalse(text.uppercased().contains("AAAABBBBCCCC"), "the script never prints the code")
        }
        XCTAssertEqual(Self.code.keyFingerprint.count, 8)
    }
}
