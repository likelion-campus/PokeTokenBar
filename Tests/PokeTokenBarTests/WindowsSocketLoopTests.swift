#if os(Windows)
import XCTest
import Foundation
import WinSDK
@testable import PokeTokenBar

/// `WinSocketLoop` over real loopback sockets: two loops in this process, or a loop and a hostile raw Winsock / TLS
/// peer. Lines starting `SOCKETLOOP-REPORT` record what Windows did (codes, timings, idle counters).
@MainActor
final class WindowsSocketLoopTests: XCTestCase {
    @MainActor final class Recorder {
        var events: [WinSocketEvent] = []
        weak var loop: WinSocketLoop?
        var autoAdmit = true
        /// Asks for the next chunk after `.ready` and after every `.data`, as the transport does.
        var autoRead = true
        var refuseAll = false

        func handle(_ e: WinSocketEvent) {
            events.append(e)
            switch e {
            case .accepted(let id):
                if refuseAll { loop?.close(id) } else if autoAdmit { loop?.admit(id) }
            case .ready(let id), .data(let id, _):
                if autoRead { loop?.receiveNext(id) }
            default:
                break
            }
        }

        var port: UInt16? {
            events.reversed().lazy.compactMap { if case .listening(let p) = $0 { p } else { nil } }.first
        }
        var listenFailures: [Int32] { events.compactMap { if case .listenFailed(let c) = $0 { c } else { nil } } }
        var accepted: [WinConnID] { events.compactMap { if case .accepted(let id) = $0 { id } else { nil } } }
        var readyIDs: [WinConnID] { events.compactMap { if case .ready(let id) = $0 { id } else { nil } } }
        func of(_ id: WinConnID) -> [WinSocketEvent] { events.filter { $0.connID == id } }
        func isReady(_ id: WinConnID) -> Bool { events.contains(.ready(id)) }
        func chunks(_ id: WinConnID) -> [Data] {
            events.compactMap { if case .data(let i, let d) = $0, i == id { d } else { nil } }
        }
        func data(_ id: WinConnID) -> Data { chunks(id).reduce(into: Data()) { $0.append($1) } }
        func byteCount(_ id: WinConnID) -> Int { chunks(id).reduce(0) { $0 + $1.count } }
        func closings(_ id: WinConnID) -> [WinCloseReason] {
            events.compactMap { if case .closed(let i, let r) = $0, i == id { r } else { nil } }
        }
        func closed(_ id: WinConnID) -> WinCloseReason? { closings(id).first }
    }

    private struct Side {
        let loop: WinSocketLoop
        let rec: Recorder
    }

    private static let code = TeamCode(parsing: "PTB-AAAA-BBBB-CCCC")!
    private static let otherCode = TeamCode(parsing: "PTB-DDDD-EEEE-FFFF")!

    private func side(connectTimeout: TimeInterval = WinSocketLoop.connectAttemptTimeout,
                      maxQueuedBytes: Int = WinSocketLoop.maxQueuedBytes) -> Side {
        XCTAssertTrue(Raw.started)
        let rec = Recorder()
        let loop = WinSocketLoop(deliver: { rec.handle($0) }, connectTimeout: connectTimeout, maxQueuedBytes: maxQueuedBytes)
        rec.loop = loop
        loop.start()
        return Side(loop: loop, rec: rec)
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func v4(_ port: UInt16) -> WinSocketAddress { WinSocketAddress(family: .ipv4, host: "127.0.0.1", port: port) }

    private func listening(_ s: Side, code: TeamCode = WindowsSocketLoopTests.code) async throws -> UInt16 {
        s.loop.listen(code: code)
        let up = await waitUntil(5) { s.rec.port != nil }
        XCTAssertTrue(up, "no .listening: \(s.rec.events)")
        return try XCTUnwrap(s.rec.port)
    }

    /// One more ready link from `client` to `server`; returns (server-side id, client-side id).
    private func link(_ server: Side, _ client: Side, port: UInt16) async throws -> (server: WinConnID, client: WinConnID) {
        let known = Set(server.rec.readyIDs)
        let cid = client.loop.dial([v4(port)], code: Self.code)
        let up = await waitUntil(5) { client.rec.isReady(cid) && server.rec.readyIDs.contains { !known.contains($0) } }
        XCTAssertTrue(up, "not ready: client \(client.rec.of(cid)) server \(server.rec.events.suffix(3))")
        let sid = try XCTUnwrap(server.rec.readyIDs.first { !known.contains($0) })
        return (sid, cid)
    }

    private static func counter(_ i: Int) -> Data { withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) } }

    // MARK: the brief's tests

    func testDialAndAcceptReachReadyAndExchangeData() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        XCTAssertNotEqual(port, 0, "an ephemeral port was bound and reported")
        let (sid, cid) = try await link(server, client, port: port)
        XCTAssertEqual(Array(server.rec.of(sid).prefix(2)), [.accepted(sid), .ready(sid)])
        XCTAssertEqual(client.rec.of(cid).first, .ready(cid))

        // Task 16's TLS-PSK client and server, joined by this loop: one frame each way.
        let ping = try TeamWire.encode(.profileRequest)
        let emote = TeamMessage.emote(TeamEmote(kind: .jump, targetMemberID: nil))
        let pong = try TeamWire.encode(emote)
        client.loop.send(ping, on: cid)
        server.loop.send(pong, on: sid)
        let moved = await waitUntil(5) { server.rec.data(sid) == ping && client.rec.data(cid) == pong }
        XCTAssertTrue(moved, "server got \(server.rec.data(sid).count) B, client got \(client.rec.data(cid).count) B")
        var forward = TeamWire.FrameDecoder(), backward = TeamWire.FrameDecoder()
        let got = try forward.append(server.rec.data(sid)), gotBack = try backward.append(client.rec.data(cid))
        XCTAssertEqual(got, [.profileRequest])
        XCTAssertEqual(gotBack, [emote])
        print("SOCKETLOOP-REPORT exchange: port=\(port) server=\(server.rec.of(sid).count) events client=\(client.rec.of(cid).count) events")
    }

    func testEventsArriveInOrderUnderLoad() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let (sid, cid) = try await link(server, client, port: try await listening(server))
        let n = 10_000
        let start = Date()
        for i in 0..<n {
            client.loop.send(Self.counter(i), on: cid)
            server.loop.send(Self.counter(n - i), on: sid)
        }
        let all = await waitUntil(30) { server.rec.byteCount(sid) == n * 8 && client.rec.byteCount(cid) == n * 8 }
        XCTAssertTrue(all, "server \(server.rec.byteCount(sid)) client \(client.rec.byteCount(cid)) of \(n * 8)")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(server.rec.data(sid), (0..<n).reduce(into: Data()) { $0.append(Self.counter($1)) })
        XCTAssertEqual(client.rec.data(cid), (0..<n).reduce(into: Data()) { $0.append(Self.counter(n - $1)) })
        let kinds = server.rec.of(sid)
        XCTAssertEqual(Array(kinds.prefix(2)), [.accepted(sid), .ready(sid)])
        XCTAssertTrue(kinds.dropFirst(2).allSatisfy { if case .data = $0 { true } else { false } })

        client.loop.close(cid)
        let ended = await waitUntil(5) { server.rec.closed(sid) != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(server.rec.of(sid).last, .closed(sid, .remoteClosed), "the end comes after every byte")
        XCTAssertEqual(client.rec.closings(cid), [], "close(_:) is silent")
        print("SOCKETLOOP-REPORT order: \(n) sends each way in \(String(format: "%.2f", elapsed)) s, "
              + "server chunks=\(server.rec.chunks(sid).count) client chunks=\(client.rec.chunks(cid).count)")
    }

    func testCloseIsSilent() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let (sid, cid) = try await link(server, client, port: port)

        // An event already on its way when close(_:) is called never arrives: the loop reads a chunk for the
        // receiveNext, posts it, then closes; the mailbox drops it.
        server.rec.autoRead = false
        client.loop.send(Data(repeating: 7, count: 300_000), on: cid)
        server.loop.receiveNext(sid)
        let first = await waitUntil(5) { server.rec.chunks(sid).count == 1 }
        XCTAssertTrue(first)
        server.loop.receiveNext(sid)
        server.loop.close(sid)
        let seen = server.rec.of(sid).count
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(server.rec.of(sid).count, seen, "after close: \(server.rec.of(sid).suffix(2))")
        let heard = await waitUntil(5) { client.rec.closed(cid) != nil }
        XCTAssertTrue(heard, "the peer hears the close")
        print("SOCKETLOOP-REPORT close with unread data: the peer saw \(String(describing: client.rec.closed(cid)))")

        // Repeated, unknown and later calls do nothing.
        server.loop.close(sid)
        server.loop.send(Data([1]), on: sid)
        server.loop.receiveNext(sid)
        server.loop.admit(sid)
        server.loop.close(WinConnID(raw: .max))

        // closeAll: every link ends silently on this side and visibly on the other; a later link works.
        server.rec.autoRead = true
        var links: [(server: WinConnID, client: WinConnID)] = []
        for _ in 0..<3 { links.append(try await link(server, client, port: port)) }
        let before = server.rec.events.count
        server.loop.closeAll()
        let allHeard = await waitUntil(5) { links.allSatisfy { client.rec.closed($0.client) != nil } }
        XCTAssertTrue(allHeard)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.rec.events.count, before, "closeAll is silent: \(server.rec.events.suffix(2))")
        let later = try await link(server, client, port: port)
        client.loop.send(Data("still".utf8), on: later.client)
        let works = await waitUntil(5) { server.rec.data(later.server) == Data("still".utf8) }
        XCTAssertTrue(works)
        let one = await waitUntil(2) { server.loop.connectionCount == 1 }
        XCTAssertTrue(one, "connections held: \(server.loop.connectionCount)")
    }

    func testReadingPausesUntilReceiveNext() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        server.rec.autoRead = false
        let (sid, cid) = try await link(server, client, port: try await listening(server))
        let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        client.loop.send(payload, on: cid)
        server.loop.receiveNext(sid)
        let one = await waitUntil(5) { server.rec.chunks(sid).count == 1 }
        XCTAssertTrue(one)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(server.rec.chunks(sid).count, 1, "one chunk per receiveNext, then the socket is not read")
        var calls = 1
        while server.rec.byteCount(sid) < payload.count, calls < 400 {
            let have = server.rec.chunks(sid).count
            server.loop.receiveNext(sid)
            calls += 1
            let next = await waitUntil(5) { server.rec.chunks(sid).count > have }
            guard next else { XCTFail("no chunk for receiveNext #\(calls)"); break }
        }
        XCTAssertEqual(server.rec.data(sid), payload)
        let sizes = server.rec.chunks(sid).map(\.count)
        XCTAssertEqual(sizes.count, calls, "exactly one chunk per receiveNext")
        XCTAssertLessThanOrEqual(sizes.max() ?? 0, TeamTransportRules.maxReadChunk)
        print("SOCKETLOOP-REPORT pull: 1 MB in \(sizes.count) chunks, max=\(sizes.max() ?? 0) min=\(sizes.min() ?? 0)")
    }

    func testPlainTCPStaysAcceptedNeverReady() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        let port = try await listening(server)

        let quiet = try XCTUnwrap(Raw.connectTCP(port))
        defer { Raw.closeSocket(quiet) }
        let in1 = await waitUntil(5) { server.rec.accepted.count == 1 }
        XCTAssertTrue(in1)
        let qid = server.rec.accepted[0]
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(server.rec.of(qid), [.accepted(qid)], "admitted, waiting for a ClientHello that never comes")

        // Garbage, a FIN without a word, and a reset without a word: each ends as a failed handshake.
        let talker = try XCTUnwrap(Raw.connectTCP(port))
        defer { Raw.closeSocket(talker) }
        XCTAssertTrue(Raw.sendAll(talker, Data("GET / HTTP/1.0\r\n\r\n".utf8)))
        let leaver = try XCTUnwrap(Raw.connectTCP(port))
        defer { Raw.closeSocket(leaver) }
        Raw.shutdownSend(leaver)
        let resetter = try XCTUnwrap(Raw.connectTCP(port))
        Raw.reset(resetter)
        let ended = await waitUntil(5) {
            server.rec.accepted.count == 4 && server.rec.accepted.dropFirst().allSatisfy { server.rec.closed($0) != nil }
        }
        XCTAssertTrue(ended, "\(server.rec.events)")
        for id in server.rec.accepted.dropFirst() {
            guard case .handshakeFailed(let text)? = server.rec.closed(id) else {
                XCTFail("\(id): \(server.rec.of(id))"); continue
            }
            print("SOCKETLOOP-REPORT plain TCP \(id): handshakeFailed(\(text))")
            XCTAssertFalse(server.rec.isReady(id))
        }
        XCTAssertEqual(server.rec.of(qid), [.accepted(qid)], "the quiet one is untouched")
        let held = await waitUntil(2) { server.loop.connectionCount == 1 }
        XCTAssertTrue(held, "connections held: \(server.loop.connectionCount)")
    }

    func testRefusedDialReportsUnreachable() async throws {
        let client = side()
        defer { client.loop.shutdown() }
        let start = Date()
        let id = client.loop.dial([v4(Raw.freePort())], code: Self.code)
        let done = await waitUntil(10) { client.rec.closed(id) != nil }
        XCTAssertTrue(done)
        let elapsed = Date().timeIntervalSince(start)
        // 10061 on every build: WSAPoll reports the refusal (about 2 s here), and where it does not (before Windows 10
        // 2004) the attempt's deadline reads SO_ERROR instead of assuming a timeout.
        XCTAssertEqual(client.rec.of(id), [.closed(id, .unreachable(10061))], "WSAECONNREFUSED")
        print("SOCKETLOOP-REPORT refused dial: \(client.rec.of(id)) after \(String(format: "%.2f", elapsed)) s")

        let none = client.loop.dial([], code: Self.code)
        let bogus = client.loop.dial([WinSocketAddress(family: .ipv4, host: "not-an-address", port: 1)], code: Self.code)
        let both = await waitUntil(5) { client.rec.closed(none) != nil && client.rec.closed(bogus) != nil }
        XCTAssertTrue(both)
        XCTAssertEqual(client.rec.closed(none), .unreachable(10049), "WSAEADDRNOTAVAIL: nothing to dial")
        XCTAssertEqual(client.rec.closed(bogus), .unreachable(10022), "WSAEINVAL: not an address")
        XCTAssertEqual(client.loop.connectionCount, 0)
    }

    func testDifferentCodeClosesWithHandshakeFailed() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let cid = client.loop.dial([v4(port)], code: Self.otherCode)
        let ended = await waitUntil(5) {
            client.rec.closed(cid) != nil && server.rec.accepted.first.map { server.rec.closed($0) != nil } == true
        }
        XCTAssertTrue(ended, "client \(client.rec.events) server \(server.rec.events)")
        let sid = try XCTUnwrap(server.rec.accepted.first)
        for (who, reason) in [("client", client.rec.closed(cid)), ("server", server.rec.closed(sid))] {
            guard case .handshakeFailed(let text)? = reason else { XCTFail("\(who): \(String(describing: reason))"); continue }
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains(Self.code.normalized) || text.contains(Self.otherCode.normalized))
            print("SOCKETLOOP-REPORT different code, \(who): \(text)")
        }
        XCTAssertFalse(client.rec.isReady(cid))
        XCTAssertFalse(server.rec.isReady(sid))
    }

    /// F20: cycles and context switches of the I/O threads, plus the loop's own count of `WSAPoll` returns.
    func testIdleLoopDoesNotWake() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        var links: [(server: WinConnID, client: WinConnID)] = []
        for _ in 0..<8 { links.append(try await link(server, client, port: port)) }   // every one armed for reading
        let quiet = (0..<2).compactMap { _ in Raw.connectTCP(port) }                    // admitted, never handshake
        defer { quiet.forEach(Raw.closeSocket) }
        let accepted = await waitUntil(5) { server.rec.accepted.count == 10 }
        XCTAssertTrue(accepted)
        try await Task.sleep(nanoseconds: 500_000_000)

        let tids = [server.loop.ioThreadID, client.loop.ioThreadID]
        let wakes0 = [server.loop.wakeups, client.loop.wakeups]
        let cs0 = try tids.map { try XCTUnwrap(ThreadStats.contextSwitches($0), "NtQuerySystemInformation") }
        let cy0 = try tids.map { try XCTUnwrap(ThreadStats.cycles($0), "QueryThreadCycleTime") }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let wakes1 = [server.loop.wakeups, client.loop.wakeups]
        let cs1 = try tids.map { try XCTUnwrap(ThreadStats.contextSwitches($0)) }
        let cy1 = try tids.map { try XCTUnwrap(ThreadStats.cycles($0)) }
        let dw = zip(wakes1, wakes0).map { $0 - $1 }
        let dcs = zip(cs1, cs0).map { Int($0) - Int($1) }
        let dcy = zip(cy1, cy0).map { $0 &- $1 }
        print("SOCKETLOOP-REPORT idle 5 s, 16 ready link ends + 2 silent TCP + listener: wakeups=\(dw) "
              + "context_switches=\(dcs) cycles=\(dcy) (server, client)")
        // Our code runs only when WSAPoll returns, so the loop's own count is the strict check. A context switch with
        // no WSAPoll return is the scheduler (an APC, a sampler), not this loop waking: a few are tolerated, and the
        // cycles bound follows from that.
        XCTAssertEqual(dw, [0, 0], "WSAPoll returned while idle")
        XCTAssertTrue(dcs.allSatisfy { $0 <= 2 }, "context switches without a WSAPoll return: \(dcs)")
        XCTAssertTrue(dcy.allSatisfy { $0 < 1_000_000 }, "cycles \(dcy)")

        // The links were idle, not dead.
        client.loop.send(Data("after".utf8), on: links[0].client)
        server.loop.send(Data("idle".utf8), on: links[7].server)
        let alive = await waitUntil(5) {
            server.rec.data(links[0].server) == Data("after".utf8) && client.rec.data(links[7].client) == Data("idle".utf8)
        }
        XCTAssertTrue(alive)
    }

    func testShutdownJoinsTheThread() async throws {
        let a = side(), b = side()
        defer { b.loop.shutdown() }
        let port = try await listening(a)
        let (_, cid) = try await link(a, b, port: port)
        let tid = a.loop.ioThreadID
        XCTAssertNotEqual(tid, 0)
        let thread = try XCTUnwrap(OpenThread(DWORD(0x0010_0800), false, tid))   // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
        defer { _ = CloseHandle(thread) }
        XCTAssertEqual(WaitForSingleObject(thread, 0), DWORD(258), "WAIT_TIMEOUT: running before shutdown")
        let seen = a.rec.events.count
        a.loop.shutdown()
        XCTAssertEqual(WaitForSingleObject(thread, 0), DWORD(0), "WAIT_OBJECT_0: the thread had exited when shutdown returned")
        a.loop.shutdown()
        _ = a.loop.dial([v4(port)], code: Self.code)
        a.loop.listen(code: Self.code)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(a.rec.events.count, seen, "nothing delivered after shutdown")
        XCTAssertEqual(a.loop.connectionCount, 0)
        let heard = await waitUntil(5) { b.rec.closed(cid) != nil }
        XCTAssertTrue(heard, "the peer saw the link end")
        XCTAssertEqual(b.rec.closed(cid), .remoteClosed)
    }

    // MARK: hostile peers and the details

    func testAnInboundLinkGetsNoTLSUntilAdmitted() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        // The main thread is held, so the server's .accepted cannot reach the handler that admits it: the server
        // loop holds the connection with no TLS, and the client, its ClientHello sent, hears nothing back.
        let cid = client.loop.dial([v4(port)], code: Self.code)
        let taken = holdMain(3) { server.loop.connectionCount == 1 }
        XCTAssertTrue(taken)
        holdMain(0.2) { false }
        let quiet0 = client.loop.wakeups
        holdMain(1) { false }
        XCTAssertEqual(client.loop.wakeups, quiet0, "the server sent nothing before admit")
        let up = await waitUntil(5) { client.rec.isReady(cid) && server.rec.readyIDs.count == 1 }
        XCTAssertTrue(up)
        let sid = try XCTUnwrap(server.rec.readyIDs.first)
        XCTAssertEqual(Array(server.rec.of(sid).prefix(2)), [.accepted(sid), .ready(sid)])
    }

    func testBytesOpenSSLAlreadyHoldsAreDeliveredOnReceiveNext() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        server.rec.autoRead = false
        let (sid, cid) = try await link(server, client, port: try await listening(server))
        // Records of 1000 B then 4 × 16 KB: a 64 KB read ends 1000 B into the last record, so OpenSSL keeps 1000
        // decrypted bytes while the socket has nothing left to signal.
        let head = Data(repeating: 1, count: 1000), body = Data(repeating: 2, count: 65_536)
        client.loop.send(head, on: cid)
        client.loop.send(body, on: cid)
        try await Task.sleep(nanoseconds: 500_000_000)
        server.loop.receiveNext(sid)
        let first = await waitUntil(5) { server.rec.chunks(sid).count == 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(server.rec.chunks(sid).first?.count, TeamTransportRules.maxReadChunk)
        server.loop.receiveNext(sid)
        let second = await waitUntil(3) { server.rec.chunks(sid).count == 2 }
        XCTAssertTrue(second, "the bytes OpenSSL held came with the next receiveNext")
        XCTAssertEqual(server.rec.chunks(sid).last?.count, 1000)
        XCTAssertEqual(server.rec.data(sid), head + body)
    }

    func testAPeerThatNeverReadsIsCutAtTheSendBound() async throws {
        let server = side(), client = side(maxQueuedBytes: 1_048_576)
        defer { server.loop.shutdown(); client.loop.shutdown() }
        server.rec.autoRead = false   // the server never asks for a byte
        let (_, cid) = try await link(server, client, port: try await listening(server))
        let sent = await pourUntilCut(client, cid)
        XCTAssertEqual(client.rec.closings(cid), [.error(10055)], "WSAENOBUFS, reported once")
        let gone = await waitUntil(2) { client.loop.connectionCount == 0 }
        XCTAssertTrue(gone)
        print("SOCKETLOOP-REPORT never-reading peer: cut after \(sent) blocks of 256 KB with a 1 MB bound")
    }

    func testAResetMidReadIsReportedOnce() async throws {
        let server = side(), client = side(maxQueuedBytes: 1_048_576)
        defer { server.loop.shutdown(); client.loop.shutdown() }
        server.rec.autoRead = false
        let port = try await listening(server)
        let (sid, cid) = try await link(server, client, port: port)
        server.loop.receiveNext(sid)
        _ = await pourUntilCut(client, cid)   // the client's cut is abortive: an RST reaches the server mid-stream
        XCTAssertGreaterThan(server.rec.chunks(sid).count, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        var calls = 0
        while server.rec.closed(sid) == nil, calls < 2000 {
            let have = server.rec.of(sid).count
            server.loop.receiveNext(sid)
            calls += 1
            guard await waitUntil(2, { server.rec.of(sid).count > have }) else { XCTFail("no event for read #\(calls)"); break }
        }
        let reasons = server.rec.closings(sid)
        print("SOCKETLOOP-REPORT reset mid-read: \(reasons) after \(server.rec.byteCount(sid)) B in \(calls) more reads")
        XCTAssertEqual(reasons, [.error(10054)], "WSAECONNRESET, reported once")
        XCTAssertEqual(server.rec.of(sid).last, .closed(sid, .error(10054)), "nothing after the end")
        // The loop is unharmed.
        server.rec.autoRead = true
        let again = try await link(server, client, port: port)
        client.loop.send(Data("next".utf8), on: again.client)
        let works = await waitUntil(5) { server.rec.data(again.server) == Data("next".utf8) }
        XCTAssertTrue(works)
    }

    /// Sends 256 KB blocks, a few ms apart (so the loop writes each), until the link is cut. Returns the blocks sent.
    private func pourUntilCut(_ s: Side, _ id: WinConnID) async -> Int {
        let block = Data(repeating: 0x5a, count: 262_144)
        var sent = 0
        while s.rec.closed(id) == nil, sent < 256 {
            s.loop.send(block, on: id)
            sent += 1
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        let cut = await waitUntil(5) { s.rec.closed(id) != nil }
        XCTAssertTrue(cut, "never cut after \(sent) blocks")
        return sent
    }

    func testAHalfClosedPeerDeliversItsDataThenClosed() async throws {
        let server = side(maxQueuedBytes: 64 * 1_048_576)
        defer { server.loop.shutdown() }
        server.rec.autoRead = false
        let port = try await listening(server)
        let s = try XCTUnwrap(Raw.connectTCP(port))
        let tls = WinTLSSession(context: try WinTLSContext(code: Self.code, role: .client), socket: UInt(s))
        defer { tls.close(); Raw.closeSocket(s) }
        var step = tls.handshake()
        for _ in 0..<1000 where step == .wantRead || step == .wantWrite {
            try await Task.sleep(nanoseconds: 5_000_000)
            step = tls.handshake()
        }
        XCTAssertEqual(step, .done)
        let up = await waitUntil(5) { server.rec.readyIDs.count == 1 }
        XCTAssertTrue(up)
        let sid = server.rec.readyIDs[0]

        // The peer never reads: what we send for it piles up past the kernel's buffers, so the link is polled for
        // writing while we are not reading it.
        for _ in 0..<64 { server.loop.send(Data(repeating: 3, count: 262_144), on: sid) }
        let payload = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0) })   // fits the socket buffers unread
        var written = 0
        for _ in 0..<2500 where written < payload.count {
            let (n, st) = tls.write(payload.subdata(in: written..<min(payload.count, written + 16_384)))
            written += n
            if n == 0 { XCTAssertTrue(st == .wantWrite || st == .wantRead, "\(st)"); try await Task.sleep(nanoseconds: 2_000_000) }
        }
        XCTAssertEqual(written, payload.count)
        Raw.shutdownSend(s)   // FIN, no close_notify; the socket could still read (it never does)
        try await Task.sleep(nanoseconds: 300_000_000)
        // POLLHUP never clears: a link waiting to write while it is not read must leave the poll set at the FIN
        // rather than wake the loop over and over.
        let w0 = server.loop.wakeups
        try await Task.sleep(nanoseconds: 500_000_000)
        let spun = server.loop.wakeups - w0
        XCTAssertLessThanOrEqual(spun, 1, "wakeups in 0.5 s after the FIN: \(spun)")
        XCTAssertEqual(server.rec.of(sid), [.accepted(sid), .ready(sid)], "nothing read before receiveNext")

        var calls = 0
        while server.rec.closed(sid) == nil, calls < 100 {
            let have = server.rec.of(sid).count
            server.loop.receiveNext(sid)
            calls += 1
            guard await waitUntil(2, { server.rec.of(sid).count > have }) else { XCTFail("no event for read #\(calls)"); break }
        }
        XCTAssertEqual(server.rec.data(sid), payload, "every byte before the FIN")
        XCTAssertEqual(server.rec.of(sid).last, .closed(sid, .remoteClosed))
        print("SOCKETLOOP-REPORT half-close: \(server.rec.byteCount(sid)) B then \(server.rec.closings(sid)); wakeups after FIN=\(spun)")
    }

    func testAFloodOfConnectionsIsRefusedCheaply() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        server.rec.refuseAll = true   // as the transport does past admitsInbound
        let port = try await listening(server)
        try await Task.sleep(nanoseconds: 300_000_000)
        let handles0 = try XCTUnwrap(ThreadStats.handleCount())
        let socks = await rawConnections(300, port: port)
        let all = await waitUntil(15) { server.rec.accepted.count == socks.count }
        XCTAssertTrue(all, "accepted \(server.rec.accepted.count) of \(socks.count)")
        XCTAssertGreaterThanOrEqual(socks.count, 200)
        let drained = await waitUntil(5) { server.loop.connectionCount == 0 }
        XCTAssertTrue(drained, "connections held: \(server.loop.connectionCount)")
        socks.forEach(Raw.closeSocket)
        try await Task.sleep(nanoseconds: 300_000_000)
        let handles1 = try XCTUnwrap(ThreadStats.handleCount())
        print("SOCKETLOOP-REPORT flood: \(socks.count) connections refused; process handles \(handles0) -> \(handles1)")
        // A leak per refused connection would show as >= socks.count; a tenth of it leaves room for the runtime's own
        // handles (threads, events) without hiding a per-connection leak.
        XCTAssertLessThan(Int(handles1) - Int(handles0), socks.count / 10, "no handle per refused connection")
        XCTAssertTrue(server.rec.events.allSatisfy {
            switch $0 { case .ready, .data, .closed: false; default: true }
        }, "a refused connection is never heard of again")
    }

    func testTheListenerPausesWhileAdmissionsAreOwed() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        server.rec.refuseAll = true
        let port = try await listening(server)
        // The main thread is held (a stall, as a long main-thread write would cause): every .accepted waits
        // unanswered, so only the cap stops the loop. The kernel backlog completes the connects without us.
        let socks = (0..<100).compactMap { _ in Raw.connectTCP(port) }
        defer { socks.forEach(Raw.closeSocket) }
        XCTAssertEqual(socks.count, 100)
        let cap = WinSocketLoop.maxAwaitingAdmission
        let full = holdMain(5) { server.loop.connectionCount >= cap }
        XCTAssertTrue(full)
        holdMain(0.5) { false }
        XCTAssertEqual(server.loop.connectionCount, cap, "no more sockets of ours while 64 answers are owed")
        XCTAssertEqual(server.rec.accepted.count, 0, "nothing was delivered while the main thread was held")
        let rest = await waitUntil(10) { server.rec.accepted.count == 100 }
        XCTAssertTrue(rest, "accepting resumes: \(server.rec.accepted.count)")
        let drained = await waitUntil(5) { server.loop.connectionCount == 0 }
        XCTAssertTrue(drained)
    }

    func testListenerRefusesAPortHijack() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        let port = try await listening(server)
        for host in ["127.0.0.1", "0.0.0.0", "::1", "::"] {
            let code = Raw.bindWithReuse(host, port)
            print("SOCKETLOOP-REPORT hijack bind \(host):\(port) with SO_REUSEADDR -> \(code)")
            XCTAssertNotEqual(code, 0, "\(host): another socket bound our port")
        }
        // The wake pair: a socket that took either port with SO_REUSEADDR would receive (steal) the wake datagrams.
        let (receiver, sender) = server.loop.wakePorts
        XCTAssertTrue(receiver != 0 && sender != 0)
        for wake in [receiver, sender] {
            let code = Raw.bindWithReuse("127.0.0.1", wake, udp: true)
            print("SOCKETLOOP-REPORT hijack bind of the wake port 127.0.0.1:\(wake) with SO_REUSEADDR -> \(code)")
            XCTAssertNotEqual(code, 0, "another socket bound a wake port")
        }
    }

    func testListenReportsATakenPortAndStopListeningSilencesIt() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        let taken = try XCTUnwrap(Raw.exclusiveListener())
        defer { Raw.closeSocket(taken.socket) }
        server.loop.listen(code: Self.code, port: taken.port)
        let failed = await waitUntil(5) { !server.rec.listenFailures.isEmpty }
        XCTAssertTrue(failed)
        print("SOCKETLOOP-REPORT listen on a taken port: \(server.rec.listenFailures)")
        XCTAssertTrue([10048, 10013].contains(server.rec.listenFailures.first ?? 0), "WSAEADDRINUSE or WSAEACCES")
        XCTAssertNil(server.rec.port)

        server.loop.listen(code: Self.code)
        server.loop.stopListening()   // in the same turn: the .listening already on its way is held back
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(server.rec.port, "\(server.rec.events)")
        let port = try await listening(server)
        XCTAssertNotEqual(port, 0, "the loop listens again when asked")
    }

    func testAClosedIDNeverReachesANewConnection() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let first = try await link(server, client, port: port)
        client.loop.close(first.client)
        let second = try await link(server, client, port: port)   // Windows likely hands it the freed SOCKET value
        client.loop.send(Data("old".utf8), on: first.client)
        client.loop.send(Data("new".utf8), on: second.client)
        let arrived = await waitUntil(5) { server.rec.data(second.server) == Data("new".utf8) }
        XCTAssertTrue(arrived)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.rec.data(second.server), Data("new".utf8))
        XCTAssertEqual(server.rec.data(first.server), Data())
    }

    func testDialReachesTheListenerOverIPv6AndParsesAddresses() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let id = client.loop.dial([WinSocketAddress(family: .ipv6, host: "::1", port: port)], code: Self.code)
        let up = await waitUntil(5) { client.rec.isReady(id) }
        XCTAssertTrue(up, "\(client.rec.of(id))")

        func parse(_ host: String) -> [UInt8]? {
            WinSocketLoop.socketAddress(WinSocketAddress(family: host.contains(":") ? .ipv6 : .ipv4, host: host, port: 0x1234))
        }
        let scoped = try XCTUnwrap(parse("fe80::1%7"))
        XCTAssertEqual(scoped.count, 28)
        XCTAssertEqual(Array(scoped[0..<4]), [23, 0, 0x12, 0x34])
        XCTAssertEqual(Array(scoped[8..<10]), [0xfe, 0x80])
        XCTAssertEqual(scoped[23], 1)
        XCTAssertEqual(Array(scoped[24..<28]), [7, 0, 0, 0], "the scope id (interface index) of a link-local address")
        XCTAssertEqual(parse("fe80:0:0:0:0:0:0:1%7"), scoped, "the uncompressed form WinDNSSD produces")
        XCTAssertEqual(parse("[::1]")?.count, 28)
        XCTAssertEqual(parse("[fe80::1%7]"), scoped, "brackets around a scoped address")
        XCTAssertEqual(parse("192.168.0.9").map { Array($0[0..<8]) }, [2, 0, 0x12, 0x34, 192, 168, 0, 9])
        XCTAssertNil(parse("fe80::1%eth0"))
        XCTAssertNil(parse("10.0.0.1%3"))
        XCTAssertNil(parse("ptb-host.local"))
    }

    func testASlowAddressGivesWayToTheNextOne() async throws {
        let server = side(), client = side(connectTimeout: 0.3)
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let dead = Raw.freePort()
        // A connect that hangs is needed. Windows answers a refused loopback connect only after retrying its SYN
        // (about 2 s on the runner), which is long enough; a build that refuses at once cannot show the deadline here.
        var start = Date()
        let probe = side()
        let measured = probe.loop.dial([v4(dead)], code: Self.code)
        _ = await waitUntil(10) { probe.rec.closed(measured) != nil }
        let refusal = Date().timeIntervalSince(start)
        probe.loop.shutdown()
        if refusal < 0.6 {
            throw XCTSkip("a refused loopback connect took \(refusal) s on this build: no hanging connect to cut")
        }
        start = Date()
        let lone = client.loop.dial([v4(dead)], code: Self.code)
        let done = await waitUntil(5) { client.rec.closed(lone) != nil }
        XCTAssertTrue(done)
        let loneTime = Date().timeIntervalSince(start)
        // The deadline cut it: well before the refusal measured above. The code is what SO_ERROR says at the deadline
        // (0 mid-retry gives WSAETIMEDOUT; a build that already knows the refusal says 10061).
        XCTAssertLessThan(loneTime, min(1.5, refusal - 0.2), "the attempt deadline, not the refusal, ended it")
        XCTAssertTrue([.unreachable(10060), .unreachable(10061)].contains(client.rec.closed(lone)),
                      "\(String(describing: client.rec.closed(lone)))")
        start = Date()
        let id = client.loop.dial([v4(dead), v4(port)], code: Self.code)
        let up = await waitUntil(5) { client.rec.isReady(id) }
        XCTAssertTrue(up, "\(client.rec.of(id))")
        print("SOCKETLOOP-REPORT slow address: alone \(client.rec.of(lone)) in \(String(format: "%.2f", loneTime)) s; "
              + "then the next address ready in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        // No deadline is left once the dials are done: the loop sleeps again.
        try await Task.sleep(nanoseconds: 200_000_000)
        let w0 = client.loop.wakeups
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(client.loop.wakeups, w0, "no timeout left behind")
    }

    // MARK: review round

    /// A wake datagram that is dropped (a loopback filter) or whose send fails must not leave the loop deaf.
    func testALostWakeIsHealedByTheNextCommand() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let (sid, cid) = try await link(server, client, port: try await listening(server))

        client.loop.injectWakeFaults(drop: 1, fail: 0)
        client.loop.send(Data("A".utf8), on: cid)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.rec.data(sid), Data(), "the dropped wake left the loop asleep")
        client.loop.send(Data("B".utf8), on: cid)   // more than wakeResendMs later: the wake goes out again
        let healed = await waitUntil(5) { server.rec.data(sid) == Data("AB".utf8) }
        XCTAssertTrue(healed, "got \(String(decoding: server.rec.data(sid), as: UTF8.self))")
        XCTAssertEqual(client.loop.wakeResends, 1)

        client.loop.injectWakeFaults(drop: 0, fail: 1)
        client.loop.send(Data("C".utf8), on: cid)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.rec.data(sid), Data("AB".utf8), "the failed wake left the loop asleep")
        client.loop.send(Data("D".utf8), on: cid)   // the failed wake was not claimed: this one sends it
        let retried = await waitUntil(5) { server.rec.data(sid) == Data("ABCD".utf8) }
        XCTAssertTrue(retried, "got \(String(decoding: server.rec.data(sid), as: UTF8.self))")
        XCTAssertEqual(client.loop.wakeFailures, 1)
    }

    func testAnUnansweredAcceptIsClosedByTheLoop() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        server.rec.autoAdmit = false   // the handler neither admits nor closes
        let port = try await listening(server)
        let socks = await rawConnections(100, port: port)
        defer { socks.forEach(Raw.closeSocket) }
        XCTAssertEqual(socks.count, 100)
        let all = await waitUntil(10) { server.rec.accepted.count == 100 }
        XCTAssertTrue(all, "a forgotten answer must not stop the listener at 64: \(server.rec.accepted.count)")
        let drained = await waitUntil(5) { server.loop.connectionCount == 0 }
        XCTAssertTrue(drained, "connections held: \(server.loop.connectionCount)")
        XCTAssertEqual(server.loop.unansweredAccepts, 100)
        XCTAssertTrue(server.rec.events.allSatisfy { switch $0 { case .ready, .data, .closed: false; default: true } })
        // One answered inside the handler is kept and not counted.
        server.rec.autoAdmit = true
        let kept = try XCTUnwrap(Raw.connectTCP(port))
        defer { Raw.closeSocket(kept) }
        let held = await waitUntil(5) { server.loop.connectionCount == 1 }
        XCTAssertTrue(held)
        XCTAssertEqual(server.loop.unansweredAccepts, 100)
    }

    func testABrokenListenerIsReportedOnceAndNotRetried() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        let port = try await listening(server)
        server.loop.injectAcceptFailure(10050)   // WSAENETDOWN from accept, as a listener that broke after .listening
        try await Task.sleep(nanoseconds: 100_000_000)
        let s = try XCTUnwrap(Raw.connectTCP(port))   // makes the listener readable
        defer { Raw.closeSocket(s) }
        let failed = await waitUntil(5) { server.rec.listenFailures == [10050] }
        XCTAssertTrue(failed, "\(server.rec.events)")
        let w0 = server.loop.wakeups
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertLessThanOrEqual(server.loop.wakeups - w0, 1, "nothing retries the broken listener")
        XCTAssertEqual(server.rec.accepted, [])
        let before = server.rec.events.count
        server.loop.listen(code: Self.code)
        let again = await waitUntil(5) {
            server.rec.events.dropFirst(before).contains { if case .listening = $0 { true } else { false } }
        }
        XCTAssertTrue(again, "the owner listens again: \(server.rec.events.suffix(2))")
    }

    func testStartAfterShutdownFailsAndReleasingTheLoopShutsItDown() async throws {
        let b = side()
        defer { b.loop.shutdown() }
        let port = try await listening(b)
        var thread: HANDLE?
        var sid: WinConnID?
        do {
            let a = side()   // dropped at the end of this scope without shutdown()
            sid = try await link(b, a, port: port).server
            thread = OpenThread(DWORD(0x0010_0800), false, a.loop.ioThreadID)   // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
        }
        let h = try XCTUnwrap(thread)
        defer { _ = CloseHandle(h) }
        XCTAssertEqual(WaitForSingleObject(h, 0), DWORD(0), "releasing the loop joined its thread (WAIT_OBJECT_0)")
        let bSide = try XCTUnwrap(sid)
        let ended = await waitUntil(5) { b.rec.closed(bSide) != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(b.rec.closed(bSide), .remoteClosed, "its links were closed as by shutdown()")

        let c = side()
        c.loop.shutdown()
        XCTAssertFalse(c.loop.start(), "a loop does not start again after shutdown")
        c.loop.listen(code: Self.code)
        _ = c.loop.dial([v4(port)], code: Self.code)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(c.rec.events, [])
        XCTAssertEqual(c.loop.connectionCount, 0)
    }

    func testPauseAcceptingLeavesConnectionsToTheKernel() async throws {
        let server = side()
        defer { server.loop.shutdown() }
        server.rec.refuseAll = true
        let port = try await listening(server)
        server.loop.pauseAccepting()
        try await Task.sleep(nanoseconds: 100_000_000)
        let w0 = server.loop.wakeups
        let socks = await rawConnections(5, port: port)
        defer { socks.forEach(Raw.closeSocket) }
        XCTAssertEqual(socks.count, 5, "the kernel backlog completes them")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.loop.wakeups, w0, "a paused listener costs the loop nothing")
        XCTAssertEqual(server.rec.accepted.count, 0)
        server.loop.resumeAccepting()
        let resumed = await waitUntil(5) { server.rec.accepted.count == 5 }
        XCTAssertTrue(resumed)
    }

    /// On Wi-Fi a 16 KB record arrives in many pieces; loopback delivers it whole. A relay that forwards one byte per
    /// send (TCP_NODELAY) makes every TLS record, handshake ones included, arrive a byte at a time.
    func testTLSThroughAByteAtATimeRelay() async throws {
        let server = side(), client = side()
        defer { server.loop.shutdown(); client.loop.shutdown() }
        let port = try await listening(server)
        let relay = try XCTUnwrap(ByteRelay(target: port))
        defer { relay.stop() }
        let w0 = server.loop.wakeups
        let start = Date()
        let cid = client.loop.dial([v4(relay.port)], code: Self.code)
        let up = await waitUntil(20) { client.rec.isReady(cid) && server.rec.readyIDs.count == 1 }
        XCTAssertTrue(up, "client \(client.rec.of(cid)) server \(server.rec.events)")
        let sid = try XCTUnwrap(server.rec.readyIDs.first)
        let upward = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })     // three records
        let downward = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        client.loop.send(upward, on: cid)
        server.loop.send(downward, on: sid)
        let moved = await waitUntil(60) {
            server.rec.byteCount(sid) == upward.count && client.rec.byteCount(cid) == downward.count
        }
        XCTAssertTrue(moved, "server \(server.rec.byteCount(sid)) client \(client.rec.byteCount(cid))")
        XCTAssertEqual(server.rec.data(sid), upward)
        XCTAssertEqual(client.rec.data(cid), downward)
        let stats = relay.stats
        let wakes = server.loop.wakeups - w0
        print("SOCKETLOOP-REPORT byte relay: \(stats.writes) one-byte sends for \(stats.bytes) B in "
              + "\(String(format: "%.2f", Date().timeIntervalSince(start))) s; server wakeups=\(wakes), "
              + "server chunks=\(server.rec.chunks(sid).count)")
        XCTAssertEqual(stats.writes, stats.bytes, "the relay sent every byte on its own")
        XCTAssertGreaterThan(wakes, 100, "the server read records in pieces, not whole")
    }

    /// Holds the main thread (no event can be delivered) until `condition` or `seconds`; the I/O threads run on.
    @discardableResult
    private func holdMain(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Sleep(5)
        }
        return condition()
    }

    // MARK: raw peers

    private func rawConnections(_ count: Int, port: UInt16) async -> [SOCKET] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SOCKET], Never>) in
            Thread {
                var out: [SOCKET] = []
                for _ in 0..<count {
                    if let s = Raw.connectTCP(port) { out.append(s) }
                }
                continuation.resume(returning: out)
            }.start()
        }
    }
}

/// Plain Winsock, no loop: the hostile side of the tests. Any thread.
private enum Raw {
    static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    static func address(_ host: String, _ port: UInt16) -> [UInt8] {
        WinSocketLoop.socketAddress(WinSocketAddress(family: host.contains(":") ? .ipv6 : .ipv4, host: host, port: port))!
    }

    static func noDelay(_ s: SOCKET) { setOption(s, 6, 1, 1) }   // IPPROTO_TCP, TCP_NODELAY

    static func setNonBlocking(_ s: SOCKET) {
        var mode: u_long = 1
        _ = ioctlsocket(s, Int32(bitPattern: 0x8004_667E), &mode)
    }

    /// Blocking connect (the kernel completes it from the listener's backlog), then non-blocking. nil if refused.
    static func connectTCP(_ port: UInt16, host: String = "127.0.0.1") -> SOCKET? {
        _ = started
        let a = address(host, port)
        let s = socket(a.count == 28 ? 23 : 2, 1, 6)
        guard s != SOCKET.max else { return nil }
        let r = a.withUnsafeBytes { connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) }
        if r != 0 { _ = closesocket(s); return nil }
        setNonBlocking(s)
        return s
    }

    static func sendAll(_ s: SOCKET, _ d: Data) -> Bool {
        var sent = 0
        for _ in 0..<2000 where sent < d.count {
            let n = d.subdata(in: sent..<d.count).withUnsafeBytes {
                send(s, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
            }
            if n > 0 { sent += Int(n) } else { Sleep(1) }
        }
        return sent == d.count
    }

    static func shutdownSend(_ s: SOCKET) { _ = shutdown(s, 1) }   // SD_SEND

    static func reset(_ s: SOCKET) {
        let linger: [UInt8] = [1, 0, 0, 0]
        _ = linger.withUnsafeBytes { setsockopt(s, 0xffff, 0x0080, $0.baseAddress!.assumingMemoryBound(to: CChar.self), 4) }
        _ = closesocket(s)
    }

    static func closeSocket(_ s: SOCKET) { _ = closesocket(s) }

    static func boundPort(_ s: SOCKET) -> UInt16 {
        var buffer = [UInt8](repeating: 0, count: 128)
        var length: Int32 = 128
        _ = buffer.withUnsafeMutableBytes { getsockname(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length) }
        return UInt16(buffer[2]) << 8 | UInt16(buffer[3])
    }

    static func bindTo(_ s: SOCKET, _ a: [UInt8]) -> Int32 {
        let r = a.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) }
        return r == 0 ? 0 : WSAGetLastError()
    }

    private static func setOption(_ s: SOCKET, _ level: Int32, _ name: Int32, _ value: Int32) {
        var v = value
        _ = withUnsafePointer(to: &v) { $0.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(s, level, name, $0, 4) } }
    }

    /// A port nothing listens on (bound, read, released).
    static func freePort() -> UInt16 {
        _ = started
        let s = socket(2, 1, 6)
        defer { _ = closesocket(s) }
        _ = bindTo(s, address("127.0.0.1", 0))
        return boundPort(s)
    }

    /// 0 when a socket with SO_REUSEADDR could bind host:port, else the Winsock error.
    static func bindWithReuse(_ host: String, _ port: UInt16, udp: Bool = false) -> Int32 {
        let a = address(host, port)
        let s = socket(a.count == 28 ? 23 : 2, udp ? 2 : 1, udp ? 17 : 6)
        defer { _ = closesocket(s) }
        setOption(s, 0xffff, 4, 1)   // SO_REUSEADDR
        return bindTo(s, a)
    }

    /// Another program's listener: [::]:0 with SO_EXCLUSIVEADDRUSE.
    static func exclusiveListener() -> (socket: SOCKET, port: UInt16)? {
        _ = started
        let s = socket(23, 1, 6)
        guard s != SOCKET.max else { return nil }
        setOption(s, 41, 27, 0)   // IPV6_V6ONLY off
        setOption(s, 0xffff, ~4, 1)   // SO_EXCLUSIVEADDRUSE
        guard bindTo(s, address("::", 0)) == 0, listen(s, 4) == 0 else { _ = closesocket(s); return nil }
        return (s, boundPort(s))
    }
}

/// A TCP relay on 127.0.0.1 for one connection: whatever arrives on one side leaves on the other one byte per send,
/// with TCP_NODELAY, so the far end receives every record in pieces as on a slow Wi-Fi. Its own thread.
private final class ByteRelay: @unchecked Sendable {
    let port: UInt16
    private let listener: SOCKET
    private let target: UInt16
    private let lock = NSLock()
    private var stopping = false
    private var counted = (bytes: 0, writes: 0)
    private let done = DispatchSemaphore(value: 0)

    init?(target: UInt16) {
        _ = Raw.started
        let s = socket(2, 1, 6)
        guard s != SOCKET.max else { return nil }
        guard Raw.bindTo(s, Raw.address("127.0.0.1", 0)) == 0, listen(s, 4) == 0 else { _ = closesocket(s); return nil }
        Raw.setNonBlocking(s)
        listener = s
        port = Raw.boundPort(s)
        self.target = target
        Thread { [self] in self.run() }.start()
    }

    var stats: (bytes: Int, writes: Int) { lock.lock(); defer { lock.unlock() }; return counted }
    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        done.wait()
        _ = closesocket(listener)
    }

    private func run() {
        defer { done.signal() }
        var a = SOCKET.max
        while a == SOCKET.max, !isStopping {
            a = accept(listener, nil, nil)
            if a == SOCKET.max { Sleep(2) }
        }
        guard a != SOCKET.max else { return }
        guard let b = Raw.connectTCP(target) else { _ = closesocket(a); return }
        defer { _ = closesocket(a); _ = closesocket(b) }
        Raw.setNonBlocking(a)
        Raw.noDelay(a)
        Raw.noDelay(b)
        var open = [true, true]   // a → b, b → a
        var buffer = [CChar](repeating: 0, count: 4096)
        while (open[0] || open[1]), !isStopping {
            var fds = [WSAPOLLFD(fd: a, events: open[0] ? 0x0100 : 0, revents: 0),
                       WSAPOLLFD(fd: b, events: open[1] ? 0x0100 : 0, revents: 0)]
            _ = fds.withUnsafeMutableBufferPointer { WSAPoll($0.baseAddress, 2, 20) }
            for i in 0..<2 where open[i] && fds[i].revents != 0 {
                let (from, to) = i == 0 ? (a, b) : (b, a)
                let n = recv(from, &buffer, 4096, 0)
                if n > 0 {
                    forward(buffer, Int(n), to)
                } else if n == 0 || WSAGetLastError() != 10035 {
                    open[i] = false
                    _ = shutdown(to, 1)   // SD_SEND: pass the end on
                }
            }
        }
    }

    private func forward(_ buffer: [CChar], _ count: Int, _ to: SOCKET) {
        buffer.withUnsafeBufferPointer { p in
            for i in 0..<count {
                while send(to, p.baseAddress! + i, 1, 0) != 1 {
                    if WSAGetLastError() != 10035 || isStopping { return }
                    Sleep(1)
                }
                lock.lock(); counted.bytes += 1; counted.writes += 1; lock.unlock()
            }
        }
    }
}

/// Per-thread wakeups and cycles (F20), and the process handle count.
private enum ThreadStats {
    private typealias NtQuery = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias Counter64 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias Counter32 = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32

    /// `ContextSwitches` of one thread of this process from `NtQuerySystemInformation(SystemProcessInformation)`
    /// (x64 layout, as in WindowsSelftest's sampler).
    static func contextSwitches(_ tid: DWORD) -> UInt32? {
        guard let query = WinDynamic.symbol("ntdll.dll", "NtQuerySystemInformation", as: NtQuery.self) else { return nil }
        let me = UInt(GetCurrentProcessId())
        var size: UInt32 = 1 << 20
        while true {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            var needed: UInt32 = 0
            let status = query(5, buffer, size, &needed)
            if status == Int32(bitPattern: 0xC000_0004) {   // STATUS_INFO_LENGTH_MISMATCH
                size = max(size * 2, needed + 65_536)
                continue
            }
            guard status >= 0 else { return nil }
            var offset = 0
            while true {
                let next = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let threads = Int(buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                if buffer.loadUnaligned(fromByteOffset: offset + 0x50, as: UInt.self) == me {
                    for t in 0..<threads {
                        let base = offset + 0x100 + t * 0x50
                        let id = UInt32(truncatingIfNeeded: buffer.loadUnaligned(fromByteOffset: base + 48, as: UInt.self))
                        if id == tid { return buffer.loadUnaligned(fromByteOffset: base + 64, as: UInt32.self) }
                    }
                    return nil
                }
                if next == 0 { return nil }
                offset += next
            }
        }
    }

    static func cycles(_ tid: DWORD) -> UInt64? {
        guard let read = WinDynamic.symbol("kernel32.dll", "QueryThreadCycleTime", as: Counter64.self),
              let h = OpenThread(0x0800, false, tid) else { return nil }   // THREAD_QUERY_LIMITED_INFORMATION
        defer { _ = CloseHandle(h) }
        var value: UInt64 = 0
        return read(h, &value) != 0 ? value : nil
    }

    static func handleCount() -> UInt32? {
        guard let read = WinDynamic.symbol("kernel32.dll", "GetProcessHandleCount", as: Counter32.self) else { return nil }
        var value: UInt32 = 0
        return read(GetCurrentProcess(), &value) != 0 ? value : nil
    }
}
#endif
