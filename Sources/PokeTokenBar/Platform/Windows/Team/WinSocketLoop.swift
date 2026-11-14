#if os(Windows)
import Foundation
import WinSDK
import CTeamTLS

/// Names one connection of a `WinSocketLoop`. Never reused in a process, so a stale id can never reach a newer
/// connection, even when Windows hands the newer one the same SOCKET value.
struct WinConnID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64
    var description: String { "conn#\(raw)" }
}

enum WinCloseReason: Sendable, Equatable {
    /// TLS did not finish: a different team code, a peer that is not ours, or a connection lost mid-handshake.
    case handshakeFailed(String)
    /// No address of a dial could be connected; the Winsock code of the last attempt.
    case unreachable(Int32)
    /// The peer ended the link: close_notify, or a FIN without one.
    case remoteClosed
    /// A socket error (reset 10054, aborted 10053), or 10055 when the peer stopped reading and our queue for it
    /// passed `WinSocketLoop.maxQueuedBytes`.
    case error(Int32)
}

enum WinSocketEvent: Sendable, Equatable {
    /// `.listenFailed` comes instead of `.listening`, or later when a working listener breaks; either way the
    /// listener is closed and nothing retries it: listen again (the Mac transport waits 5 s).
    case listening(port: UInt16), listenFailed(Int32)
    /// An inbound connection. Answer it inside the handler with `admit(_:)` (TLS starts) or `close(_:)` (refused,
    /// nothing allocated). A handler that does neither gets it closed by the loop (counted, logged once).
    case accepted(WinConnID)
    case ready(WinConnID)
    /// At most `TeamTransportRules.maxReadChunk` bytes; then reading pauses until `receiveNext`.
    case data(WinConnID, Data)
    /// Never after `close(_:)` / `closeAll()` / `shutdown()`.
    case closed(WinConnID, WinCloseReason)

    var connID: WinConnID? {
        switch self {
        case .accepted(let id), .ready(let id), .data(let id, _), .closed(let id, _): return id
        case .listening, .listenFailed: return nil
        }
    }
}

/// Every team socket and every `SSL*` on Windows lives on one thread of this object. It blocks in
/// `WSAPoll` and wakes only for a socket that is ready, a command (a loopback UDP datagram from the
/// caller's thread), or the deadline of a dial attempt that is still connecting. With nothing in flight
/// the timeout is INFINITE, so an idle loop never runs.
///
/// Events reach `deliver` on the main queue in the order the loop produced them: one
/// `DispatchQueue.main.async` per empty → non-empty mailbox, then one `deliver` call per event. An event is
/// checked right before it is delivered, so nothing for an id arrives after `close(id)` returned, even an event
/// already queued or one later in the same flush.
///
/// Receive is pulled, like Network.framework's: after `.ready`, each `receiveNext(id)` delivers at most one
/// `.data` of up to `maxReadChunk` bytes and then stops reading that socket, so TCP holds a fast sender back.
///
/// Lifecycle: one `start()`, one `shutdown()` (it joins the thread). A loop does not start again: `start()` after
/// `shutdown()` logs and returns false. Releasing the last reference without `shutdown()` shuts it down then.
///
/// Call the methods from the main thread (they are lock-safe from any thread, but the order of events relative
/// to calls is defined for one calling thread).
final class WinSocketLoop: @unchecked Sendable {
    /// How long one dial attempt may stay in TCP connect before the next address is tried.
    static let connectAttemptTimeout: TimeInterval = 4
    /// Bytes queued for one link and not yet taken by the socket. Twice the receive burst: an honest receiver
    /// cuts a sender off long before this, so only a peer that stopped reading reaches it.
    static let maxQueuedBytes = 2 * Int(TeamTransportRules.receiveBurst)
    /// Inbound connections reported but not yet answered. At this many (only while the main thread is behind), the
    /// listener is not polled, so a connection flood waits in the kernel backlog instead of becoming sockets of ours.
    static let maxAwaitingAdmission = 64
    /// `.listenFailed` code when the TLS context could not be built (no Winsock code applies).
    static let tlsSetupFailed: Int32 = -1

    private let engine: WinSocketEngine

    /// - Parameter deliver: runs on the main queue, once per event, in order.
    init(deliver: @escaping @MainActor (WinSocketEvent) -> Void,
         connectTimeout: TimeInterval = WinSocketLoop.connectAttemptTimeout,
         maxQueuedBytes: Int = WinSocketLoop.maxQueuedBytes) {
        engine = WinSocketEngine(deliver: deliver, connectTimeoutMs: UInt64(max(1, connectTimeout * 1000)),
                                 maxQueued: maxQueuedBytes)
    }

    /// The I/O thread holds the engine, not this handle, so dropping the handle cannot leave the thread running.
    deinit { engine.shutdown() }

    /// Starts Winsock (once per loop, paired with `shutdown`) and the I/O thread. Commands given before it run then.
    /// False when Winsock could not start (logged; listens and dials then report failure) or after `shutdown()`.
    @discardableResult func start() -> Bool { engine.start() }

    /// Closes every socket without reporting it, waits until the I/O thread has exited, and releases Winsock.
    /// Nothing is delivered afterwards. Calls made later do nothing.
    func shutdown() { engine.shutdown() }

    /// Listens on dual-stack `[::]:0` (IPv4 arrives mapped) with `SO_EXCLUSIVEADDRUSE`. Replaces an earlier listener.
    /// Reports `.listening(port:)` with the bound port, or `.listenFailed(code)`.
    func listen(code: TeamCode) { engine.listen(code: code, port: 0) }

    /// Test seam: a fixed port, to prove a taken port is reported.
    func listen(code: TeamCode, port: UInt16) { engine.listen(code: code, port: port) }

    /// Closes the listener. No listener event of earlier `listen` calls is delivered afterwards.
    /// Connections already accepted stay.
    func stopListening() { engine.stopListening() }

    /// Stops taking connections off the listener (they wait in, and past its size are refused by, the kernel
    /// backlog) until `resumeAccepting()`. For a transport at its link limit: a flood then costs no main-thread hop.
    func pauseAccepting() { engine.setAcceptPaused(true) }
    func resumeAccepting() { engine.setAcceptPaused(false) }

    /// Connects to the addresses in order (each attempt gets `connectTimeout`), then runs the TLS client handshake.
    /// Reports `.ready(id)`, or `.closed(id, .unreachable(code))` when no address connects, or
    /// `.closed(id, .handshakeFailed(text))`.
    func dial(_ addresses: [WinSocketAddress], code: TeamCode) -> WinConnID { engine.dial(addresses, code: code) }

    /// Starts the TLS server handshake on an `.accepted` connection. Until then the loop reads nothing from it.
    func admit(_ id: WinConnID) { engine.admit(id) }

    /// Asks for the next `.data` of a link (after `.ready`; one asked before `.ready` is kept for it).
    func receiveNext(_ id: WinConnID) { engine.receiveNext(id) }

    /// Queues bytes for a link; written once it is ready. Past `maxQueuedBytes` unsent, the link is closed with
    /// `.error(10055)` (reported).
    func send(_ data: Data, on id: WinConnID) { engine.send(data, on: id) }

    /// Closes one connection, silently. Unknown or already closed ids are ignored.
    func close(_ id: WinConnID) { engine.close(id) }

    /// Closes every connection that exists now, silently (the listener stays).
    func closeAll() { engine.closeAll() }

    // MARK: test seams

    /// The I/O thread (0 before `start`).
    var ioThreadID: DWORD { engine.counters.threadID }
    /// How many times `WSAPoll` has returned: each one is a wakeup of the I/O thread.
    var wakeups: Int { engine.counters.pollReturns }
    /// Connections the I/O thread holds a socket for, as of its last pass.
    var connectionCount: Int { engine.counters.openConnections }
    /// `.accepted` connections the owner's handler left unanswered, closed by the loop.
    var unansweredAccepts: Int { engine.counters.unanswered }
    /// Wake datagrams sent again because the previous one had not woken the loop after `wakeResendMs`.
    var wakeResends: Int { engine.counters.wakeResends }
    /// Wake datagrams whose `send` failed.
    var wakeFailures: Int { engine.counters.wakeFailures }
    /// The two local ports of the wake pair (receiver, sender), 0 before `start`.
    var wakePorts: (UInt16, UInt16) { engine.counters.wakePorts }
    /// The next `drop` wake datagrams count as sent but are never sent; the next `fail` ones fail.
    func injectWakeFaults(drop: Int, fail: Int) { engine.injectWakeFaults(drop: drop, fail: fail) }
    /// The next `accept` on a readable listener fails with `code`, as a listener that broke would.
    func injectAcceptFailure(_ code: Int32) { engine.injectAcceptFailure(code) }

    /// A `sockaddr_in` (16 bytes) or `sockaddr_in6` (28 bytes) for numeric host text: IPv4 dotted, IPv6 in any
    /// form, optionally in brackets, with an optional numeric `%<interface index>` scope for link-local IPv6
    /// (`fe80::1%7` or `[fe80::1%7]`).
    static func socketAddress(_ a: WinSocketAddress) -> [UInt8]? {
        var host = Substring(a.host)
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        var scope: UInt32 = 0
        if let percent = host.firstIndex(of: "%") {
            guard let s = UInt32(host[host.index(after: percent)...]) else { return nil }
            scope = s
            host = host[..<percent]
        }
        let text = String(host)
        if text.contains(":") {
            var b = [UInt8](repeating: 0, count: 28)
            b[0] = UInt8(WS.afInet6)
            b[2] = UInt8(a.port >> 8); b[3] = UInt8(a.port & 0xff)
            let parsed = b.withUnsafeMutableBytes { inet_pton(WS.afInet6, text, $0.baseAddress! + 8) }
            guard parsed == 1 else { return nil }
            for i in 0..<4 { b[24 + i] = UInt8((scope >> (8 * UInt32(i))) & 0xff) }
            return b
        }
        guard scope == 0 else { return nil }
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = UInt8(WS.afInet)
        b[2] = UInt8(a.port >> 8); b[3] = UInt8(a.port & 0xff)
        let parsed = b.withUnsafeMutableBytes { inet_pton(WS.afInet, text, $0.baseAddress! + 4) }
        return parsed == 1 ? b : nil
    }
}

/// The loop itself: owned by the I/O thread while it runs and by the `WinSocketLoop` handle.
private final class WinSocketEngine: @unchecked Sendable {
    private static let writeSlice = 65_536
    /// A wake datagram that has not woken the loop after this long is sent again by the next command. The loop takes
    /// commands within microseconds; only a lost datagram (or a loop busy for this long) gets here.
    static let wakeResendMs: UInt64 = 100

    private let deliver: @MainActor (WinSocketEvent) -> Void
    private let connectTimeoutMs: UInt64
    private let maxQueued: Int

    // Shared between the caller and the I/O thread, under `lock`.
    private let lock = NSLock()
    private enum State { case idle, running, stopped, failed(Int32) }
    private var state = State.idle
    private var commands: [Command] = []
    private var wakePending = false
    private var wakeSentAt: UInt64 = 0
    private var wakeSender = SOCKET.max
    private var mailbox: [Posted] = []
    private var flushScheduled = false
    /// Ids the owner still wants to hear about: added at `dial` / accept, removed by `close` or the delivered `.closed`.
    private var live = Set<WinConnID>()
    /// Bumped by `closeAll`; a connection born before the bump is closed by it, a later one is not.
    private var epoch = 0
    private var listenGeneration = 0
    /// The `.accepted` being delivered right now, and whether its handler answered it.
    private var answering: WinConnID?
    private var answered = false
    private var dropWakes = 0
    private var failWakes = 0
    struct Counters {
        var threadID: DWORD = 0
        var pollReturns = 0
        var openConnections = 0
        var unanswered = 0
        var wakeResends = 0
        var wakeFailures = 0
        var wakePorts: (UInt16, UInt16) = (0, 0)
    }
    private var counts = Counters()

    // The I/O thread only.
    private var wakeReceiver = SOCKET.max
    private var conns: [WinConnID: Conn] = [:]
    private var listener: Listener?
    private var acceptPaused = false
    private var injectedAcceptFailure: Int32?
    private var clientContext: (code: TeamCode, context: WinTLSContext)?
    private var awaitingAdmission = 0
    private var stopping = false
    private var toFlush: [Conn] = []
    private var loggedPollFailure = false

    // The thread that calls start/shutdown.
    private var threadHandle: HANDLE?
    private let finished = DispatchSemaphore(value: 0)

    init(deliver: @escaping @MainActor (WinSocketEvent) -> Void, connectTimeoutMs: UInt64, maxQueued: Int) {
        self.deliver = deliver
        self.connectTimeoutMs = connectTimeoutMs
        self.maxQueued = maxQueued
    }

    var counters: Counters { locked { counts } }

    // MARK: lifecycle

    func start() -> Bool {
        lock.lock()
        switch state {
        case .idle:
            lock.unlock()
        case .running:
            lock.unlock()
            return true
        case .failed:
            lock.unlock()
            return false
        case .stopped:
            lock.unlock()
            AppLog.write("team: a socket loop was started again after shutdown; ignored (one start, one shutdown)")
            return false
        }
        var data = WSADATA()
        let started = WSAStartup(0x0202, &data)
        guard started == 0 else { fail(started); return false }
        guard let pair = Self.wakePair() else {
            let code = WSAGetLastError()
            _ = WSACleanup()
            fail(code)
            return false
        }
        wakeReceiver = pair.receiver
        lock.lock()
        wakeSender = pair.sender
        counts.wakePorts = (pair.receiverPort, pair.senderPort)
        state = .running
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let tid = GetCurrentThreadId()
            self.lock.lock(); self.counts.threadID = tid; self.lock.unlock()
            ready.signal()
            self.run()
        }
        thread.name = "PokeTokenBar team sockets"
        thread.start()
        ready.wait()
        threadHandle = OpenThread(DWORD(0x0010_0000 | 0x0800), false, counters.threadID)  // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
        return true
    }

    func shutdown() {
        lock.lock()
        let wasRunning: Bool
        if case .running = state { wasRunning = true } else { wasRunning = false }
        lock.unlock()
        if wasRunning {
            enqueue(.stop)
            finished.wait()
            if let h = threadHandle {
                _ = WaitForSingleObject(h, DWORD(0xFFFF_FFFF))   // INFINITE: the thread object is signalled once it has exited
                _ = CloseHandle(h)
                threadHandle = nil
            }
        }
        lock.lock()
        state = .stopped
        live.removeAll()
        mailbox.removeAll()
        commands.removeAll()
        listenGeneration += 1
        let sender = wakeSender
        wakeSender = SOCKET.max
        lock.unlock()
        if sender != SOCKET.max { Sock.closeNow(sender) }
        if wasRunning { _ = WSACleanup() }
    }

    // MARK: API

    func listen(code: TeamCode, port: UInt16) {
        let generation = locked { () -> Int in listenGeneration += 1; return listenGeneration }
        enqueue(.listen(code, port, generation))
    }

    func stopListening() {
        locked { listenGeneration += 1 }
        enqueue(.stopListening)
    }

    func setAcceptPaused(_ paused: Bool) { enqueue(.pauseAccepting(paused)) }

    func dial(_ addresses: [WinSocketAddress], code: TeamCode) -> WinConnID {
        let id = Self.newID()
        let e = locked { () -> Int in live.insert(id); return epoch }
        enqueue(.dial(id, e, addresses, code))
        return id
    }

    func admit(_ id: WinConnID) {
        locked { if answering == id { answered = true } }
        enqueue(.admit(id))
    }

    func receiveNext(_ id: WinConnID) { enqueue(.receiveNext(id)) }

    func send(_ data: Data, on id: WinConnID) { enqueue(.send(id, data)) }

    func close(_ id: WinConnID) {
        locked {
            live.remove(id)
            if answering == id { answered = true }
        }
        enqueue(.close(id))
    }

    func closeAll() {
        let below = locked { () -> Int in epoch += 1; live.removeAll(); return epoch }
        enqueue(.closeAll(below))
    }

    func injectWakeFaults(drop: Int, fail: Int) { locked { dropWakes = drop; failWakes = fail } }

    func injectAcceptFailure(_ code: Int32) { enqueue(.injectAcceptFailure(code)) }

    // MARK: commands and the mailbox

    private enum Command {
        case listen(TeamCode, UInt16, Int)
        case stopListening
        case pauseAccepting(Bool)
        case dial(WinConnID, Int, [WinSocketAddress], TeamCode)
        case admit(WinConnID)
        case receiveNext(WinConnID)
        case send(WinConnID, Data)
        case close(WinConnID)
        case closeAll(Int)
        case injectAcceptFailure(Int32)
        case stop
    }

    private struct Posted {
        let event: WinSocketEvent
        let listenGeneration: Int?
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private nonisolated(unsafe) static var lastID: UInt64 = 0
    private nonisolated(unsafe) static let idLock = NSLock()

    private static func newID() -> WinConnID {
        idLock.lock()
        defer { idLock.unlock() }
        lastID += 1
        return WinConnID(raw: lastID)
    }

    /// The wake: one datagram per empty → non-empty command queue. A datagram that has not woken the loop after
    /// `wakeResendMs` is sent again by the next command (a filter may drop loopback datagrams), and a failed send
    /// leaves the wake unclaimed so the next command tries again. No timer: an idle loop stays asleep.
    private func enqueue(_ command: Command) {
        lock.lock()
        switch state {
        case .stopped:
            lock.unlock()
        case .failed(let code):
            lock.unlock()
            refuse(command, code)
        case .idle:
            commands.append(command)
            lock.unlock()
        case .running:
            commands.append(command)
            var failure: Int32?
            let now = GetTickCount64()
            if !wakePending || now &- wakeSentAt >= Self.wakeResendMs {
                if wakePending { counts.wakeResends += 1 }
                let code = sendWake()
                if code == 0 {
                    wakePending = true
                    wakeSentAt = now
                } else {
                    wakePending = false
                    counts.wakeFailures += 1
                    if counts.wakeFailures == 1 { failure = code }
                }
            }
            lock.unlock()
            if let failure {
                AppLog.write("team: the socket loop's wake datagram was not sent (Winsock \(failure)); the next command retries")
            }
        }
    }

    /// Under `lock`. 0 when the datagram went out.
    private func sendWake() -> Int32 {
        if dropWakes > 0 { dropWakes -= 1; return 0 }
        if failWakes > 0 { failWakes -= 1; return WS.noBufs }
        return Sock.sendByte(wakeSender)
    }

    /// Winsock or the wake pair could not start: say so once, and fail what needs an answer.
    private func fail(_ code: Int32) {
        lock.lock()
        state = .failed(code)
        let pending = commands
        commands = []
        lock.unlock()
        AppLog.write("team: socket loop could not start (Winsock \(code))")
        for c in pending { refuse(c, code) }
    }

    private func refuse(_ command: Command, _ code: Int32) {
        switch command {
        case .listen(_, _, let generation): post(.listenFailed(code), listenGeneration: generation)
        case .dial(let id, _, _, _): post(.closed(id, .error(code)))
        default: break
        }
    }

    /// Any thread. The first event into an empty mailbox schedules the one flush.
    private func post(_ event: WinSocketEvent, listenGeneration: Int? = nil) {
        lock.lock()
        mailbox.append(Posted(event: event, listenGeneration: listenGeneration))
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    /// I/O thread: a new inbound connection is registered as live and announced in one step, so a `closeAll` on
    /// the main thread either covers it (epoch) or comes after the owner heard of it.
    private func announce(_ id: WinConnID) -> Int {
        lock.lock()
        let e = epoch
        live.insert(id)
        mailbox.append(Posted(event: .accepted(id), listenGeneration: nil))
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.flush() } }
        return e
    }

    @MainActor private func flush() {
        lock.lock()
        let batch = mailbox
        mailbox = []
        flushScheduled = false
        lock.unlock()
        for posted in batch where stillWanted(posted) {
            guard case .accepted(let id) = posted.event else {
                deliver(posted.event)
                continue
            }
            locked { answering = id; answered = false }
            deliver(posted.event)
            let unanswered = locked { () -> Bool in
                defer { answering = nil }
                guard !answered, live.remove(id) != nil else { return false }
                counts.unanswered += 1
                return true
            }
            if unanswered {
                enqueue(.close(id))
                if counters.unanswered == 1 {
                    AppLog.write("team: an inbound connection was neither admitted nor closed by its handler; closed")
                }
            }
        }
    }

    /// Checked right before each delivery, so a `close` made by an earlier event's handler holds back the rest.
    private func stillWanted(_ posted: Posted) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .stopped = state { return false }
        if let generation = posted.listenGeneration { return generation == listenGeneration }
        guard let id = posted.event.connID, live.contains(id) else { return false }
        if case .closed = posted.event { live.remove(id) }
        return true
    }

    // MARK: the I/O thread

    private final class Conn {
        enum Phase { case connecting, awaitingAdmission, handshaking, ready }
        let id: WinConnID
        let epoch: Int
        var phase: Phase
        var socket = SOCKET.max
        var context: WinTLSContext?
        var session: WinTLSSession?
        var attempts: [[UInt8]] = []
        var deadline: UInt64 = 0
        var lastError: Int32 = 0
        var handshakeWants: Int16 = 0
        var readArmed = false
        var readWantsWrite = false
        var writeWantsRead = false
        /// POLLHUP seen while not reading: the socket is left out of the poll set (POLLHUP never clears) until
        /// `receiveNext` reads the rest and the end.
        var hungUp = false
        var outbox: [Data] = []
        var outboxHead = 0
        var queued = 0
        var pendingFlush = false
        var closed = false

        init(id: WinConnID, epoch: Int, phase: Phase) {
            self.id = id
            self.epoch = epoch
            self.phase = phase
        }
    }

    private final class Listener {
        let socket: SOCKET
        let context: WinTLSContext
        let generation: Int
        init(socket: SOCKET, context: WinTLSContext, generation: Int) {
            self.socket = socket
            self.context = context
            self.generation = generation
        }
    }

    private func run() {
        while true {
            processCommands()
            if stopping { break }
            var fds = [WSAPOLLFD(fd: wakeReceiver, events: WS.pollRdNorm, revents: 0)]
            var owners: [Conn?] = [nil]
            var listenerIndex = -1
            if let l = listener, !acceptPaused, awaitingAdmission < WinSocketLoop.maxAwaitingAdmission {
                listenerIndex = fds.count
                fds.append(WSAPOLLFD(fd: l.socket, events: WS.pollRdNorm, revents: 0))
                owners.append(nil)
            }
            for c in conns.values {
                let events = interest(c)
                guard events != 0 else { continue }
                fds.append(WSAPOLLFD(fd: c.socket, events: events, revents: 0))
                owners.append(c)
            }
            let timeout = pollTimeout()
            // Published right before blocking: commands at the top of this pass may have closed some.
            lock.lock(); counts.openConnections = conns.count; lock.unlock()
            let n = fds.withUnsafeMutableBufferPointer { WSAPoll($0.baseAddress, ULONG($0.count), timeout) }
            lock.lock(); counts.pollReturns += 1; lock.unlock()
            if n < 0 {
                if !loggedPollFailure {
                    loggedPollFailure = true
                    AppLog.write("team: WSAPoll failed (Winsock \(WSAGetLastError())); retrying every 50 ms")
                }
                Sleep(50)   // never seen; if WSAPoll keeps failing this bounds the cost to 20 wakeups a second
                continue
            }
            if fds[0].revents != 0 { Sock.drain(wakeReceiver) }
            if listenerIndex >= 0, fds[listenerIndex].revents != 0 {
                if fds[listenerIndex].revents & (WS.pollErr | WS.pollHup | WS.pollNval) != 0 {
                    let code = listener.map { Sock.pendingError($0.socket) } ?? 0
                    listenerFailed(code != 0 ? code : WS.notSock)   // a broken listener with no error of its own
                } else {
                    acceptPending()
                }
            }
            for i in 1..<fds.count where i != listenerIndex && fds[i].revents != 0 {
                // By object, never by SOCKET value: a value closed above may already belong to a newer socket.
                guard let c = owners[i], !c.closed else { continue }
                handle(c, revents: fds[i].revents)
            }
            expireDeadlines()
        }
        for c in Array(conns.values) { closeConn(c, reason: nil) }
        if let l = listener { Sock.closeNow(l.socket) }
        listener = nil
        clientContext = nil   // every SSL_CTX is freed on this thread
        Sock.closeNow(wakeReceiver)
        wakeReceiver = SOCKET.max
        lock.lock(); counts.openConnections = 0; lock.unlock()
        ptb_tls_thread_stop()   // static OpenSSL: this thread's error queue and DRBG are not freed otherwise
        finished.signal()
    }

    private func processCommands() {
        lock.lock()
        let batch = commands
        commands = []
        wakePending = false
        lock.unlock()
        for command in batch { apply(command) }
        // Sends of one batch are written together: one TLS record per 64 KB instead of one per send.
        let flush = toFlush
        toFlush = []
        for c in flush {
            c.pendingFlush = false
            if !c.closed { flushOutbox(c) }
        }
    }

    private func apply(_ command: Command) {
        switch command {
        case .listen(let code, let port, let generation):
            openListener(code: code, port: port, generation: generation)
        case .stopListening:
            closeListener()
        case .pauseAccepting(let paused):
            acceptPaused = paused
        case .dial(let id, let e, let addresses, let code):
            startDial(id, epoch: e, addresses: addresses, code: code)
        case .admit(let id):
            guard let c = conns[id], c.phase == .awaitingAdmission, let context = c.context else { return }
            awaitingAdmission -= 1
            c.phase = .handshaking
            c.session = WinTLSSession(context: context, socket: UInt(c.socket))
            stepHandshake(c)
        case .receiveNext(let id):
            guard let c = conns[id] else { return }
            c.readArmed = true
            if c.phase == .ready { tryRead(c) }   // drains what OpenSSL already holds: no socket readiness comes for it
        case .send(let id, let data):
            guard let c = conns[id] else { return }
            queue(data, on: c)
        case .close(let id):
            if let c = conns[id] { closeConn(c, reason: nil) }
        case .closeAll(let below):
            for c in Array(conns.values) where c.epoch < below { closeConn(c, reason: nil) }
        case .injectAcceptFailure(let code):
            injectedAcceptFailure = code
        case .stop:
            stopping = true
        }
    }

    private func interest(_ c: Conn) -> Int16 {
        switch c.phase {
        case .connecting: return WS.pollWrNorm
        case .awaitingAdmission: return 0
        case .handshaking: return c.handshakeWants
        case .ready:
            if c.hungUp { return 0 }
            var events: Int16 = 0
            // Polled for reading only while armed, and then OpenSSL holds nothing: tryRead stops only on WANT_READ
            // or a full chunk, and a full chunk disarms.
            if (c.readArmed && !c.readWantsWrite) || c.writeWantsRead { events |= WS.pollRdNorm }
            if (!c.outbox.isEmpty && !c.writeWantsRead) || c.readWantsWrite { events |= WS.pollWrNorm }
            return events
        }
    }

    /// INFINITE unless a dial attempt is connecting: nothing else is ever due.
    private func pollTimeout() -> Int32 {
        var next: UInt64?
        for c in conns.values where c.phase == .connecting { next = min(next ?? c.deadline, c.deadline) }
        guard let next else { return -1 }
        let now = GetTickCount64()
        return next <= now ? 0 : Int32(clamping: next - now)
    }

    /// An attempt at its deadline is charged what the socket says (a refusal WSAPoll did not report: builds before
    /// Windows 10 2004 never report a failed connect), else WSAETIMEDOUT.
    private func expireDeadlines() {
        let now = GetTickCount64()
        for c in Array(conns.values) where !c.closed && c.phase == .connecting && c.deadline <= now {
            let code = Sock.pendingError(c.socket)
            attemptFailed(c, code != 0 ? code : WS.timedOut)
        }
    }

    // MARK: listener

    private func openListener(code: TeamCode, port: UInt16, generation: Int) {
        closeListener()
        let context: WinTLSContext
        do { context = try WinTLSContext(code: code, role: .server) } catch {
            post(.listenFailed(WinSocketLoop.tlsSetupFailed), listenGeneration: generation)
            return
        }
        let s = Sock.open(WS.afInet6, WS.sockStream, WS.ipprotoTCP)
        guard s != SOCKET.max else {
            post(.listenFailed(WSAGetLastError()), listenGeneration: generation)
            return
        }
        var any = [UInt8](repeating: 0, count: 28)   // [::]:port
        any[0] = UInt8(WS.afInet6)
        any[2] = UInt8(port >> 8); any[3] = UInt8(port & 0xff)
        guard Sock.setOption(s, WS.ipprotoIPv6, WS.ipv6V6Only, 0),
              Sock.setOption(s, WS.solSocket, WS.soExclusiveAddrUse, 1),   // no other socket may bind our port
              Sock.bindTo(s, any),
              Sock.startListening(s),
              Sock.nonBlocking(s),
              let bound = Sock.localPort(s) else {
            let code = WSAGetLastError()
            Sock.closeNow(s)
            post(.listenFailed(code), listenGeneration: generation)
            return
        }
        listener = Listener(socket: s, context: context, generation: generation)
        post(.listening(port: bound), listenGeneration: generation)
    }

    private func closeListener() {
        guard let l = listener else { return }
        Sock.closeNow(l.socket)
        listener = nil
    }

    /// A listener that broke after `.listening`: closed and reported once, like a listener that never started, so
    /// the owner restarts it on its own schedule instead of the loop retrying it.
    private func listenerFailed(_ code: Int32) {
        guard let l = listener else { return }
        Sock.closeNow(l.socket)
        listener = nil
        post(.listenFailed(code), listenGeneration: l.generation)
    }

    private func acceptPending() {
        guard let l = listener else { return }
        if let code = injectedAcceptFailure {
            injectedAcceptFailure = nil
            listenerFailed(code)
            return
        }
        while awaitingAdmission < WinSocketLoop.maxAwaitingAdmission {
            let s = Sock.acceptOne(l.socket)
            if s == SOCKET.max {
                let code = WSAGetLastError()
                if code == WS.wouldBlock { return }
                if code == WS.connReset { continue }   // gone before we took it
                listenerFailed(code)
                return
            }
            guard Sock.nonBlocking(s) else {
                Sock.abortOnClose(s)
                Sock.closeNow(s)
                continue
            }
            let id = Self.newID()
            let c = Conn(id: id, epoch: announce(id), phase: .awaitingAdmission)
            c.socket = s
            c.context = l.context
            conns[id] = c
            awaitingAdmission += 1
        }
    }

    // MARK: dial

    private func startDial(_ id: WinConnID, epoch: Int, addresses: [WinSocketAddress], code: TeamCode) {
        let c = Conn(id: id, epoch: epoch, phase: .connecting)
        conns[id] = c
        do {
            if let cached = clientContext, cached.code == code {
                c.context = cached.context
            } else {
                let context = try WinTLSContext(code: code, role: .client)
                clientContext = (code, context)
                c.context = context
            }
        } catch {
            closeConn(c, reason: .handshakeFailed("TLS setup failed: \(error)"))
            return
        }
        c.attempts = addresses.compactMap(WinSocketLoop.socketAddress)
        c.lastError = c.attempts.count < addresses.count ? WS.inval : WS.addrNotAvail
        nextAttempt(c)
    }

    private func nextAttempt(_ c: Conn) {
        while !c.attempts.isEmpty {
            let address = c.attempts.removeFirst()
            let s = Sock.open(address.count == 28 ? WS.afInet6 : WS.afInet, WS.sockStream, WS.ipprotoTCP)
            guard s != SOCKET.max else { c.lastError = WSAGetLastError(); continue }
            guard Sock.nonBlocking(s) else {
                c.lastError = WSAGetLastError()
                Sock.closeNow(s)
                continue
            }
            c.socket = s
            if Sock.connectTo(s, address) == 0 {
                connected(c)
                return
            }
            let code = WSAGetLastError()
            if code == WS.wouldBlock {
                c.deadline = GetTickCount64() + connectTimeoutMs
                return
            }
            c.lastError = code
            c.socket = SOCKET.max
            Sock.abortOnClose(s)
            Sock.closeNow(s)
        }
        closeConn(c, reason: .unreachable(c.lastError))
    }

    private func attemptFailed(_ c: Conn, _ code: Int32) {
        let s = c.socket
        c.socket = SOCKET.max
        if s != SOCKET.max {
            Sock.abortOnClose(s)
            Sock.closeNow(s)
        }
        c.lastError = code
        nextAttempt(c)
    }

    private func connected(_ c: Conn) {
        guard let context = c.context else { return }
        c.phase = .handshaking
        c.session = WinTLSSession(context: context, socket: UInt(c.socket))
        stepHandshake(c)
    }

    // MARK: TLS and I/O

    private func handle(_ c: Conn, revents: Int16) {
        let lost = revents & (WS.pollErr | WS.pollHup | WS.pollNval) != 0
        switch c.phase {
        case .connecting:
            let code = Sock.pendingError(c.socket)
            if code == 0, revents & WS.pollWrNorm != 0, !lost {
                connected(c)
            } else {
                attemptFailed(c, code != 0 ? code : WS.connRefused)
            }
        case .awaitingAdmission:
            break
        case .handshaking:
            stepHandshake(c)
            // A lost socket with the handshake still waiting would be reported again at once, forever.
            if lost, !c.closed, c.phase == .handshaking {
                closeConn(c, reason: .handshakeFailed("connection lost during the TLS handshake"))
            }
        case .ready:
            if lost {
                let code = Sock.pendingError(c.socket)
                if code != 0 || revents & (WS.pollErr | WS.pollNval) != 0 {
                    closeConn(c, reason: code != 0 ? .error(code) : .remoteClosed)
                    return
                }
            }
            if revents & (WS.pollRdNorm | WS.pollHup) != 0 {
                if c.writeWantsRead {
                    c.writeWantsRead = false
                    flushOutbox(c)
                }
                if !c.closed, c.readArmed, !c.readWantsWrite { tryRead(c) }
            }
            if !c.closed, revents & WS.pollWrNorm != 0 {
                if c.readWantsWrite {
                    c.readWantsWrite = false
                    if c.readArmed { tryRead(c) }
                }
                if !c.closed { flushOutbox(c) }
            }
            if !c.closed, revents & WS.pollHup != 0 { c.hungUp = true }
        }
    }

    private func stepHandshake(_ c: Conn) {
        guard let session = c.session else { return }
        switch session.handshake() {
        case .done:
            c.phase = .ready
            c.handshakeWants = 0
            post(.ready(c.id))
            flushOutbox(c)
            if !c.closed, c.readArmed { tryRead(c) }
        case .wantRead:
            c.handshakeWants = WS.pollRdNorm
        case .wantWrite:
            c.handshakeWants = WS.pollWrNorm
        case .failed(let text):
            closeConn(c, reason: .handshakeFailed(text))
        case .closed:
            closeConn(c, reason: .handshakeFailed("the peer closed the connection during the TLS handshake"))
        }
    }

    /// Reads until OpenSSL wants the socket or one chunk is full. A full chunk disarms, so the next read waits for
    /// `receiveNext` and starts with whatever OpenSSL still holds.
    private func tryRead(_ c: Conn) {
        guard c.phase == .ready, c.readArmed, !c.closed, let session = c.session else { return }
        let max = TeamTransportRules.maxReadChunk
        var chunk = Data()
        var end: WinCloseReason?
        reading: while chunk.count < max {
            WSASetLastError(0)
            let (data, step) = session.read(max: max - chunk.count)
            if let data {
                chunk.append(data)
                continue
            }
            switch step {
            case .wantRead, .done: break reading
            case .wantWrite: c.readWantsWrite = true; break reading
            case .closed: end = .remoteClosed; break reading
            case .failed: end = Self.failureReason(c.socket); break reading
            }
        }
        if !chunk.isEmpty {
            c.readArmed = false
            post(.data(c.id, chunk))
        }
        if let end { closeConn(c, reason: end) }
    }

    private func queue(_ data: Data, on c: Conn) {
        guard !data.isEmpty, !c.closed else { return }
        guard c.queued + data.count <= maxQueued else {
            closeConn(c, reason: .error(WS.noBufs))   // the peer stopped reading: bounded, and said so
            return
        }
        c.queued += data.count
        // Entry 0 may be mid-write (OpenSSL wants the same bytes again after WANT_WRITE), so only later ones grow.
        if c.outbox.count >= 2, c.outbox[c.outbox.count - 1].count + data.count <= Self.writeSlice {
            c.outbox[c.outbox.count - 1].append(data)
        } else {
            c.outbox.append(data.startIndex == 0 ? data : Data(data))
        }
        if c.phase == .ready, !c.pendingFlush {
            c.pendingFlush = true
            toFlush.append(c)
        }
    }

    private func flushOutbox(_ c: Conn) {
        if let failure = writeQueued(c) { closeConn(c, reason: failure) }
    }

    /// Writes what the socket takes now, in slices of at most 64 KB (the same slice again after WANT_WRITE).
    /// Returns why the link failed, if it did.
    private func writeQueued(_ c: Conn) -> WinCloseReason? {
        guard c.phase == .ready, !c.writeWantsRead, let session = c.session else { return nil }
        while let first = c.outbox.first {
            let end = min(first.count, c.outboxHead + Self.writeSlice)
            WSASetLastError(0)
            let (written, step) = session.write(first.subdata(in: c.outboxHead..<end))
            if written > 0 {
                c.outboxHead += written
                c.queued -= written
                if c.outboxHead == first.count {
                    c.outbox.removeFirst()
                    c.outboxHead = 0
                }
                continue
            }
            switch step {
            case .wantWrite, .done: return nil
            case .wantRead: c.writeWantsRead = true; return nil
            case .closed: return .remoteClosed
            case .failed: return Self.failureReason(c.socket)
            }
        }
        return nil
    }

    /// Right after a failed TLS read or write: the socket error if Winsock had one (reset, aborted), else the peer's
    /// end without close_notify.
    private static func failureReason(_ s: SOCKET) -> WinCloseReason {
        let last = WSAGetLastError()
        if last != 0, last != WS.wouldBlock { return .error(last) }
        let pending = Sock.pendingError(s)
        return pending != 0 ? .error(pending) : .remoteClosed
    }

    /// Frees the session (close_notify after a finished handshake) and the socket. Graceful (FIN) for a link that
    /// worked or ended by the peer, and after a TLS failure so the alert reaches the peer; abortive (RST, no
    /// TIME_WAIT, no lingering data) for refusals, unfinished links the owner drops, and socket errors.
    private func closeConn(_ c: Conn, reason: WinCloseReason?) {
        guard !c.closed else { return }
        c.closed = true
        conns[c.id] = nil
        if c.phase == .awaitingAdmission { awaitingAdmission -= 1 }
        let graceful: Bool
        switch reason {
        case nil: graceful = c.phase == .ready
        case .remoteClosed?, .handshakeFailed?: graceful = true
        case .unreachable?, .error?: graceful = false
        }
        if let session = c.session {
            if reason == nil, c.phase == .ready { _ = writeQueued(c) }   // one best-effort pass; never waits
            session.close()
            c.session = nil
        }
        let s = c.socket
        c.socket = SOCKET.max   // invalidated before the close: nothing below can use the value again
        if s != SOCKET.max {
            if !graceful { Sock.abortOnClose(s) }
            Sock.closeNow(s)
        }
        c.outbox = []
        c.queued = 0
        c.context = nil
        if let reason { post(.closed(c.id, reason)) }
    }

    /// A UDP pair on 127.0.0.1, each end connected to the other (only our own datagrams wake the loop) and bound with
    /// SO_EXCLUSIVEADDRUSE (no other socket can bind either port and take the datagrams).
    private static func wakePair() -> (receiver: SOCKET, sender: SOCKET, receiverPort: UInt16, senderPort: UInt16)? {
        let r = Sock.open(WS.afInet, WS.sockDgram, WS.ipprotoUDP)
        let s = Sock.open(WS.afInet, WS.sockDgram, WS.ipprotoUDP)
        let any = Sock.loopback4(port: 0)
        if r != SOCKET.max, s != SOCKET.max,
           Sock.setOption(r, WS.solSocket, WS.soExclusiveAddrUse, 1),
           Sock.setOption(s, WS.solSocket, WS.soExclusiveAddrUse, 1),
           Sock.bindTo(r, any), let rp = Sock.localPort(r),
           Sock.bindTo(s, any), let sp = Sock.localPort(s),
           Sock.connectTo(r, Sock.loopback4(port: sp)) == 0,
           Sock.connectTo(s, Sock.loopback4(port: rp)) == 0,
           Sock.nonBlocking(r), Sock.nonBlocking(s) {
            return (r, s, rp, sp)
        }
        if r != SOCKET.max { Sock.closeNow(r) }
        if s != SOCKET.max { Sock.closeNow(s) }
        return nil
    }
}

/// Winsock values the importer cannot see (macros with casts) or that read better as literals.
private enum WS {
    static let afInet: Int32 = 2, afInet6: Int32 = 23
    static let sockStream: Int32 = 1, sockDgram: Int32 = 2
    static let ipprotoTCP: Int32 = 6, ipprotoUDP: Int32 = 17, ipprotoIPv6: Int32 = 41
    static let solSocket: Int32 = 0xffff
    static let soError: Int32 = 0x1007, soLinger: Int32 = 0x0080
    static let soExclusiveAddrUse: Int32 = ~4   // ((int)(~SO_REUSEADDR))
    static let ipv6V6Only: Int32 = 27
    static let fionbio = Int32(bitPattern: 0x8004_667E)
    static let somaxconn: Int32 = 0x7fff_ffff
    static let pollRdNorm: Int16 = 0x0100, pollWrNorm: Int16 = 0x0010
    static let pollErr: Int16 = 0x0001, pollHup: Int16 = 0x0002, pollNval: Int16 = 0x0004
    static let inval: Int32 = 10022, wouldBlock: Int32 = 10035, notSock: Int32 = 10038, addrNotAvail: Int32 = 10049
    static let connReset: Int32 = 10054, noBufs: Int32 = 10055, timedOut: Int32 = 10060, connRefused: Int32 = 10061
}

/// Thin Winsock calls under names that cannot collide with `WinSocketLoop`'s own `listen`/`send`/`close`.
private enum Sock {
    static func open(_ family: Int32, _ type: Int32, _ proto: Int32) -> SOCKET { socket(family, type, proto) }

    static func nonBlocking(_ s: SOCKET) -> Bool {
        var mode: u_long = 1
        return ioctlsocket(s, WS.fionbio, &mode) == 0
    }

    static func setOption(_ s: SOCKET, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var v = value
        return withUnsafePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(s, level, name, $0, 4) }
        } == 0
    }

    /// SO_ERROR: 0 for a healthy (or connected) socket.
    static func pendingError(_ s: SOCKET) -> Int32 {
        var v: Int32 = 0
        var length: Int32 = 4
        let r = withUnsafeMutablePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(s, WS.solSocket, WS.soError, $0, &length) }
        }
        return r == 0 ? v : WSAGetLastError()
    }

    /// SO_LINGER {on, 0}: closesocket then resets the connection.
    static func abortOnClose(_ s: SOCKET) {
        let linger: [UInt8] = [1, 0, 0, 0]
        _ = linger.withUnsafeBytes { setsockopt(s, WS.solSocket, WS.soLinger, $0.baseAddress!.assumingMemoryBound(to: CChar.self), 4) }
    }

    static func bindTo(_ s: SOCKET, _ address: [UInt8]) -> Bool {
        address.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) } == 0
    }

    static func connectTo(_ s: SOCKET, _ address: [UInt8]) -> Int32 {
        address.withUnsafeBytes { connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32($0.count)) }
    }

    static func startListening(_ s: SOCKET) -> Bool { listen(s, WS.somaxconn) == 0 }

    static func acceptOne(_ s: SOCKET) -> SOCKET { accept(s, nil, nil) }

    static func localPort(_ s: SOCKET) -> UInt16? {
        var buffer = [UInt8](repeating: 0, count: 128)
        var length: Int32 = 128
        let r = buffer.withUnsafeMutableBytes { getsockname(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length) }
        guard r == 0 else { return nil }
        return UInt16(buffer[2]) << 8 | UInt16(buffer[3])
    }

    static func loopback4(port: UInt16) -> [UInt8] {
        [UInt8(WS.afInet), 0, UInt8(port >> 8), UInt8(port & 0xff), 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// 0 when the datagram went out, else the Winsock error.
    static func sendByte(_ s: SOCKET) -> Int32 {
        var byte: CChar = 1
        return send(s, &byte, 1, 0) == 1 ? 0 : WSAGetLastError()
    }

    static func drain(_ s: SOCKET) {
        var buffer = [CChar](repeating: 0, count: 64)
        while recv(s, &buffer, 64, 0) > 0 {}
    }

    static func closeNow(_ s: SOCKET) { _ = closesocket(s) }
}
#endif
