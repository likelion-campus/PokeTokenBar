#if os(Windows)
import Foundation
import WinSDK

/// An address a resolved teammate can be dialled at. `host` is numeric text (IPv4 dotted, IPv6 as eight hex groups,
/// no scope id).
struct WinSocketAddress: Equatable, Sendable {
    enum Family: Sendable { case ipv4, ipv6 }
    let family: Family
    let host: String
    let port: UInt16
}

// MARK: - callback contexts

/// What a `windns` callback receives through `pQueryContext`. The thread-pool callbacks cannot capture, so everything
/// they touch hangs off one of these. Each is created with `Unmanaged.passRetained` and released exactly once
/// (`releaseRetain`), either by the one-shot callback itself or, after a cancel, a few seconds later: Windows gives
/// no promise about a callback that is already in flight when the cancel returns, so the object outlives the cancel.
private class CallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var released = false
    private var retained: Unmanaged<CallbackContext>?
    /// How long a cancelled operation's memory stays valid for a callback that was already running.
    static let cancelGrace: TimeInterval = 5

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    /// Returns true for the caller that closed it.
    @discardableResult func close() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = open; open = false; return was
    }
    func retainForWindows() -> UnsafeMutableRawPointer {
        let u = Unmanaged.passRetained(self)
        lock.lock(); retained = u; lock.unlock()
        return u.toOpaque()
    }
    func releaseRetain() {
        lock.lock()
        guard !released, let u = retained else { lock.unlock(); return }
        released = true; lock.unlock()
        u.release()
    }
    func releaseRetainAfterGrace() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) { self.releaseRetain() }
    }
}

private final class WideString {
    let pointer: UnsafeMutablePointer<UInt16>
    init(_ string: String) {
        let units = Array(string.utf16) + [0]
        pointer = .allocate(capacity: units.count)
        pointer.initialize(from: units, count: units.count)
    }
    deinit { pointer.deallocate() }
}

private final class BrowseContext: CallbackContext {
    let deliver: @MainActor (WinDNSSD.Event) -> Void
    let queryName = WideString(DNSSDName.defaultServiceType + ".local")
    let request = UnsafeMutablePointer<DNS_SERVICE_BROWSE_REQUEST>.allocate(capacity: 1)
    let cancel = UnsafeMutablePointer<DNS_SERVICE_CANCEL>.allocate(capacity: 1)
    init(deliver: @escaping @MainActor (WinDNSSD.Event) -> Void) {
        self.deliver = deliver
        request.initialize(to: DNS_SERVICE_BROWSE_REQUEST())
        cancel.initialize(to: DNS_SERVICE_CANCEL())
    }
    deinit { request.deallocate(); cancel.deallocate() }

    /// Pool thread. Drops the event when the browse was stopped; checked again on the main queue.
    func post(_ events: [WinDNSSD.Event]) {
        guard isOpen, !events.isEmpty else { return }
        let deliver = self.deliver
        DispatchQueue.main.async {
            for event in events {
                guard self.isOpen else { return }
                MainActor.assumeIsolated { deliver(event) }
            }
        }
    }
}

private final class RegisterContext: CallbackContext {
    let deliver: @MainActor (WinDNSSD.Event) -> Void
    let instanceName: String
    let fullName: WideString
    let hostName: WideString
    var serviceInstance: UnsafeMutablePointer<DNS_SERVICE_INSTANCE>?
    let request = UnsafeMutablePointer<DNS_SERVICE_REGISTER_REQUEST>.allocate(capacity: 1)
    let cancel = UnsafeMutablePointer<DNS_SERVICE_CANCEL>.allocate(capacity: 1)
    private let stateLock = NSLock()
    private var completedFlag = false
    var isCompleted: Bool { stateLock.lock(); defer { stateLock.unlock() }; return completedFlag }
    func markCompleted() { stateLock.lock(); completedFlag = true; stateLock.unlock() }

    init(instance: String, host: String, deliver: @escaping @MainActor (WinDNSSD.Event) -> Void) {
        instanceName = instance
        fullName = WideString(DNSSDName.fullName(instance: instance))
        hostName = WideString(host)
        self.deliver = deliver
        request.initialize(to: DNS_SERVICE_REGISTER_REQUEST())
        cancel.initialize(to: DNS_SERVICE_CANCEL())
    }
    deinit {
        if let serviceInstance { DnsServiceFreeInstance(serviceInstance) }
        request.deallocate(); cancel.deallocate()
    }

    /// A start failure: delivered even though the operation is closed right away.
    func fail(_ event: WinDNSSD.Event) {
        close()
        let deliver = self.deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(event) } }
        releaseRetainAfterGrace()
    }

    func post(_ event: WinDNSSD.Event) {
        guard isOpen else { return }
        let deliver = self.deliver
        DispatchQueue.main.async {
            guard self.isOpen else { return }
            MainActor.assumeIsolated { deliver(event) }
        }
    }
}

private final class ResolveContext: CallbackContext {
    let queryName: WideString
    let request = UnsafeMutablePointer<DNS_SERVICE_RESOLVE_REQUEST>.allocate(capacity: 1)
    let cancel = UnsafeMutablePointer<DNS_SERVICE_CANCEL>.allocate(capacity: 1)
    private let done: @MainActor ([WinSocketAddress]) -> Void
    init(instance: String, done: @escaping @MainActor ([WinSocketAddress]) -> Void) {
        queryName = WideString(DNSSDName.fullName(instance: instance))
        self.done = done
        request.initialize(to: DNS_SERVICE_RESOLVE_REQUEST())
        cancel.initialize(to: DNS_SERVICE_CANCEL())
    }
    deinit { request.deallocate(); cancel.deallocate() }

    /// Delivers once, on the main queue, whichever of the callback, the start failure or the timeout gets here first.
    func finish(_ addresses: [WinSocketAddress]) {
        guard close() else { return }
        let done = self.done
        DispatchQueue.main.async { MainActor.assumeIsolated { done(addresses) } }
    }
}

// MARK: - callback bodies (pool threads; no captures, so they are plain functions)

private func handleBrowse(_ status: UInt32, _ rawContext: UnsafeMutableRawPointer?, _ rawRecords: UnsafeMutableRawPointer?) {
    defer { if let rawRecords { DnsFree(rawRecords, DnsFreeRecordList) } }
    guard let rawContext else { return }
    let context = Unmanaged<BrowseContext>.fromOpaque(rawContext).takeUnretainedValue()
    guard context.isOpen else { return }
    if status != 0 { context.post([.browseFailed(Int32(bitPattern: status))]); return }
    var events: [WinDNSSD.Event] = []
    var node = rawRecords?.assumingMemoryBound(to: DNS_RECORDW.self)   // the service API always returns wide records
    while let record = node {
        if record.pointee.wType == 12, let host = record.pointee.Data.PTR.pNameHost,   // DNS_TYPE_PTR
           let label = DNSSDName.instanceLabel(fromPTR: String(decodingCString: UnsafePointer(host), as: UTF16.self)) {
            events.append(record.pointee.dwTtl == 0 ? .lost(label) : .found(label))
        }
        node = record.pointee.pNext
    }
    context.post(events)
}

private func handleRegister(_ status: UInt32, _ rawContext: UnsafeMutableRawPointer?, _ rawInstance: UnsafeMutableRawPointer?) {
    guard let rawContext else { return }
    let context = Unmanaged<RegisterContext>.fromOpaque(rawContext).takeUnretainedValue()
    context.markCompleted()
    // A callback after deregister is ignored without freeing: it may be handed our own instance back.
    guard context.isOpen else { return }
    let instance = rawInstance?.assumingMemoryBound(to: DNS_SERVICE_INSTANCE.self)
    defer { if let instance { DnsServiceFreeInstance(instance) } }
    if status != 0 { context.post(.registerFailed(Int32(bitPattern: status))); return }
    var label = context.instanceName
    if let name = instance?.pointee.pszInstanceName,
       let parsed = DNSSDName.instanceLabel(fromPTR: String(decodingCString: UnsafePointer(name), as: UTF16.self)) {
        label = parsed
    }
    context.post(.registered(label))
}

private func handleResolve(_ status: UInt32, _ rawContext: UnsafeMutableRawPointer?, _ rawInstance: UnsafeMutableRawPointer?) {
    let instance = rawInstance?.assumingMemoryBound(to: DNS_SERVICE_INSTANCE.self)
    defer { if let instance { DnsServiceFreeInstance(instance) } }
    guard let rawContext else { return }
    let context = Unmanaged<ResolveContext>.fromOpaque(rawContext).takeUnretainedValue()
    defer { context.releaseRetain() }   // one-shot: nothing of ours is referenced after this returns
    guard status == 0, let instance else { context.finish([]); return }
    let port = instance.pointee.wPort
    var addresses: [WinSocketAddress] = []
    if let p4 = instance.pointee.ip4Address {
        let text = withUnsafeBytes(of: p4.pointee) { $0.map { String($0) }.joined(separator: ".") }   // bytes are in address order
        addresses.append(WinSocketAddress(family: .ipv4, host: text, port: port))
    }
    if let p6 = instance.pointee.ip6Address {
        let text = withUnsafeBytes(of: p6.pointee) { raw -> String in
            let b = Array(raw.prefix(16))
            return stride(from: 0, to: 16, by: 2).map { String(UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]), radix: 16) }.joined(separator: ":")
        }
        addresses.append(WinSocketAddress(family: .ipv6, host: text, port: port))
    }
    context.finish(addresses)
}

// MARK: - the wrapper

/// DNS-SD for the team service `_ptbteam._tcp` through the built-in `windns` API (no Bonjour install needed).
/// Interoperates with the Mac's `NWListener.Service(name: "ptb-<12 hex>", type: "_ptbteam._tcp")` / `NWBrowser`:
/// the instance is registered as `<instance>._ptbteam._tcp.local` on host `<dns hostname>.local`, with no TXT record.
///
/// Threading: every method must be called on the main thread. `windns` calls back on a thread-pool thread; events
/// and resolve results are delivered on the main queue, and none is delivered after the call that stops it
/// (`stopBrowsing`, `deregister`, `deinit`) has returned, even one already queued.
///
/// Lifetime: each operation's request structs, strings and callback context are heap-owned and outlive the call that
/// cancels it by a grace period, so a callback already in flight when a cancel returns never touches freed memory.
final class WinDNSSD: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case registered(String), registerFailed(Int32), found(String), lost(String), browseFailed(Int32)
    }

    /// A resolve that Windows never answers is cancelled and reported as `[]` after this long.
    static let resolveTimeout: TimeInterval = 8

    private let deliver: @MainActor (Event) -> Void
    private var registration: RegisterContext?
    private var browsing: BrowseContext?

    /// - Parameter deliver: called on the main queue for every event of this object.
    init(deliver: @escaping @MainActor (Event) -> Void) {
        self.deliver = deliver
    }

    deinit {
        stopBrowsingNow()
        deregisterNow()
    }

    /// Advertises `instance` (a bare label such as `ptb-ab12cd34ef56`; non-ASCII is fine) at `port`. Replaces an
    /// earlier registration. Reports `.registered(label)` or `.registerFailed(code)`. Main thread.
    func register(instance: String, port: UInt16) {
        deregisterNow()
        let context = RegisterContext(instance: instance, host: Self.computerName() + ".local", deliver: deliver)
        guard let service = DnsServiceConstructInstance(
            UnsafePointer(context.fullName.pointer), UnsafePointer(context.hostName.pointer),
            nil, nil, port, 0, 0, 0, nil, nil) else {
            context.fail(.registerFailed(14))   // ERROR_OUTOFMEMORY
            return
        }
        context.serviceInstance = service
        context.request.pointee.Version = 1   // DNS_QUERY_REQUEST_VERSION1
        context.request.pointee.pServiceInstance = service
        context.request.pointee.pRegisterCompletionCallback = { status, rawContext, inst in
            handleRegister(status, rawContext, UnsafeMutableRawPointer(inst))
        }
        context.request.pointee.pQueryContext = context.retainForWindows()
        registration = context
        let result = Int64(DnsServiceRegister(context.request, context.cancel))
        if result != 9506 {   // DNS_REQUEST_PENDING
            registration = nil
            context.fail(.registerFailed(Int32(truncatingIfNeeded: result)))
        }
    }

    /// Withdraws the advertisement (Windows sends the goodbye record). Quiet when nothing is registered. Main thread.
    func deregister() { deregisterNow() }

    /// Starts browsing `_ptbteam._tcp.local`. Reports `.found(label)` for every PTR with a TTL above 0 (repeats are
    /// passed through, and your own instance is included) and `.lost(label)` for TTL 0. No-op while already
    /// browsing. Main thread.
    func browse() {
        guard browsing == nil else { return }
        let context = BrowseContext(deliver: deliver)
        context.request.pointee.Version = 1
        context.request.pointee.QueryName = UnsafePointer(context.queryName.pointer)
        context.request.pointee.pBrowseCallback = { status, rawContext, records in
            handleBrowse(status, rawContext, UnsafeMutableRawPointer(records))
        }
        context.request.pointee.pQueryContext = context.retainForWindows()
        browsing = context
        let result = Int64(DnsServiceBrowse(context.request, context.cancel))
        if result != 9506 {
            browsing = nil
            let code = Int32(truncatingIfNeeded: result)
            let deliver = self.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(.browseFailed(code)) } }
            context.close()
            context.releaseRetainAfterGrace()
        }
    }

    /// Stops browsing. Nothing from this browse is delivered afterwards. Main thread.
    func stopBrowsing() { stopBrowsingNow() }

    /// Looks up the port and addresses of `<instance>._ptbteam._tcp.local`. `done` runs once on the main queue with
    /// IPv4 addresses first, then IPv6; `[]` when it fails, finds no address, or takes longer than `resolveTimeout`.
    /// Main thread.
    func resolve(instance: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void) {
        let context = ResolveContext(instance: instance, done: done)
        context.request.pointee.Version = 1
        context.request.pointee.QueryName = context.queryName.pointer
        context.request.pointee.pResolveCompletionCallback = { status, rawContext, inst in
            handleResolve(status, rawContext, UnsafeMutableRawPointer(inst))
        }
        context.request.pointee.pQueryContext = context.retainForWindows()
        let result = Int64(DnsServiceResolve(context.request, context.cancel))
        if result != 9506 {
            context.finish([])
            context.releaseRetainAfterGrace()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveTimeout) {
            guard context.isOpen else { return }
            context.finish([])
            _ = DnsServiceResolveCancel(context.cancel)
            context.releaseRetainAfterGrace()
        }
    }

    // MARK: private

    private func stopBrowsingNow() {
        guard let context = browsing else { return }
        browsing = nil
        context.close()
        _ = DnsServiceBrowseCancel(context.cancel)
        context.releaseRetainAfterGrace()
    }

    private func deregisterNow() {
        guard let context = registration else { return }
        registration = nil
        let completed = context.isCompleted
        context.close()
        if !completed { _ = DnsServiceRegisterCancel(context.cancel) }
        _ = DnsServiceDeRegister(context.request, nil)
        context.releaseRetainAfterGrace()
    }

    private static func computerName() -> String {
        var buffer = [WCHAR](repeating: 0, count: 256)
        var length = DWORD(buffer.count)
        guard GetComputerNameExW(ComputerNameDnsHostname, &buffer, &length), length > 0 else { return "windows" }
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }
}
#endif
