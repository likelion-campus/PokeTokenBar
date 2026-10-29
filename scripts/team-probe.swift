// LAN probe for the team feature: Bonjour discovery + TCP with TLS-PSK.
// Standalone (Network.framework + CryptoKit only). No app code involved.
//
//   swift scripts/team-probe.swift serve <code>
//   swift scripts/team-probe.swift browse <code>
//   swift scripts/team-probe.swift browse <code> --host <host> --port <port>   (skip Bonjour)
import Foundation
import Network
import CryptoKit
import Security

let serviceType = "_ptbteam._tcp"

func usage() -> Never {
    print("""
    usage:
      swift scripts/team-probe.swift serve <code>
      swift scripts/team-probe.swift browse <code> [--host <host> --port <port>]
    <code> is any string; both sides must use the same one.
    Ctrl-C to quit.
    """)
    exit(2)
}

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

func makeParameters(code: String) -> NWParameters {
    let key = HMACSHA256Key(code)
    let tls = NWProtocolTLS.Options()
    let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = "ptb-team-v1".data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(
        tls.securityProtocolOptions,
        tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
}

func HMACSHA256Key(_ code: String) -> Data {
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data("poketokenbar.team.psk.v1".utf8),
        using: SymmetricKey(data: Data(code.utf8)))
    return Data(mac)
}

let hostName = ProcessInfo.processInfo.hostName

// Reads newline-terminated lines until the connection ends.
func receiveLines(_ conn: NWConnection, buffer: Data = Data(), onLine: @escaping (String) -> Void) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
        var buf = buffer
        if let data { buf.append(data) }
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl)
            onLine(line)
        }
        if error != nil || isComplete { return }
        receiveLines(conn, buffer: buf, onLine: onLine)
    }
}

func send(_ conn: NWConnection, _ line: String) {
    conn.send(content: Data((line + "\n").utf8), completion: .contentProcessed { err in
        if let err { log("send failed: \(err)") }
    })
}

let queue = DispatchQueue(label: "probe")
var keepAlive: [AnyObject] = []

func runServe(code: String) throws {
    let name = "probe-" + String(UUID().uuidString.prefix(8))
    let listener = try NWListener(using: makeParameters(code: code))
    listener.service = NWListener.Service(name: name, type: serviceType)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: log("listener ready, port \(listener.port?.rawValue ?? 0), advertising \(serviceType) as \"\(name)\"")
        case .failed(let e): log("listener FAILED: \(e)"); exit(1)
        default: log("listener state: \(state)")
        }
    }
    listener.serviceRegistrationUpdateHandler = { change in log("bonjour registration: \(change)") }
    listener.newConnectionHandler = { conn in
        log("incoming connection from \(conn.endpoint)")
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready: log("  [\(conn.endpoint)] TLS-PSK handshake OK")
            case .failed(let e): log("  [\(conn.endpoint)] FAILED (TLS/connection): \(e)")
            case .waiting(let e): log("  [\(conn.endpoint)] waiting: \(e)")
            case .cancelled: log("  [\(conn.endpoint)] closed")
            default: break
            }
        }
        conn.start(queue: queue)
        receiveLines(conn) { line in
            log("  [\(conn.endpoint)] got: \(line)")
            send(conn, "pong \(line)")
        }
        keepAlive.append(conn)
    }
    keepAlive.append(listener)
    listener.start(queue: queue)
}

func connect(to endpoint: NWEndpoint, label: String, code: String) {
    let conn = NWConnection(to: endpoint, using: makeParameters(code: code))
    var timer: DispatchSourceTimer?
    conn.stateUpdateHandler = { s in
        switch s {
        case .ready:
            log("[\(label)] connected, TLS-PSK handshake OK")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 3)
            t.setEventHandler {
                let ping = "ping \(hostName) \(Int(Date().timeIntervalSince1970))"
                log("[\(label)] send: \(ping)")
                send(conn, ping)
            }
            t.resume(); timer = t
        case .failed(let e): log("[\(label)] FAILED (TLS/connection): \(e)"); timer?.cancel()
        case .waiting(let e): log("[\(label)] waiting: \(e)")
        case .preparing: log("[\(label)] connecting...")
        case .cancelled: log("[\(label)] closed"); timer?.cancel()
        default: break
        }
    }
    conn.start(queue: queue)
    receiveLines(conn) { line in log("[\(label)] recv: \(line)") }
    keepAlive.append(conn)
}

func runBrowse(code: String, host: String?, port: UInt16?) {
    if let host, let port {
        log("direct mode (no Bonjour): \(host):\(port)")
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), label: "\(host):\(port)", code: code)
        return
    }
    let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
    var seen = Set<String>()
    browser.stateUpdateHandler = { s in
        switch s {
        case .ready: log("browsing for \(serviceType) ...")
        case .failed(let e): log("browse FAILED: \(e)"); exit(1)
        case .waiting(let e): log("browse waiting (local network permission?): \(e)")
        default: log("browse state: \(s)")
        }
    }
    browser.browseResultsChangedHandler = { _, changes in
        for c in changes {
            switch c {
            case .added(let r):
                let desc = "\(r.endpoint)"
                if seen.insert(desc).inserted {
                    log("FOUND \(desc)")
                    connect(to: r.endpoint, label: desc, code: code)
                }
            case .removed(let r):
                log("LOST \(r.endpoint)"); seen.remove("\(r.endpoint)")
            default: break
            }
        }
    }
    keepAlive.append(browser)
    browser.start(queue: queue)
}

// MARK: main
var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") { usage() }
guard args.count >= 2 else { usage() }
let mode = args[0], code = args[1]
var hostArg: String?, portArg: UInt16?
var i = 2
while i < args.count {
    if args[i] == "--host", i + 1 < args.count { hostArg = args[i + 1]; i += 2 }
    else if args[i] == "--port", i + 1 < args.count { portArg = UInt16(args[i + 1]); i += 2 }
    else { usage() }
}
if (hostArg == nil) != (portArg == nil) { usage() }

signal(SIGINT, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sig.setEventHandler { log("bye"); exit(0) }
sig.resume()

switch mode {
case "serve": try runServe(code: code)
case "browse": runBrowse(code: code, host: hostArg, port: portArg)
default: usage()
}
dispatchMain()
