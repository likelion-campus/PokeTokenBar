#if os(Windows)
import Foundation
import CTeamTLS

/// The same TLS-PSK the Mac's `BonjourTeamTransport.parameters(code:)` negotiates: TLS 1.2,
/// TLS_PSK_WITH_AES_128_GCM_SHA256, identity `TeamCode.pskIdentity`, key `TeamCode.pskKey`.
enum WinTLSError: Error, Equatable { case contextFailed(String) }

/// One per team code and role. Sessions keep it alive; it zeroes its key copy when freed.
final class WinTLSContext {
    enum Role { case client, server }

    fileprivate let raw: OpaquePointer

    init(code: TeamCode, role: Role) throws {
        var key: [UInt8] = code.pskKey.withUnsafeBytes { Array($0) }
        defer { for i in key.indices { key[i] = 0 } }
        let identity = String(decoding: TeamCode.pskIdentity, as: UTF8.self)
        guard key.count == 32,
              let ctx = ptb_tls_ctx_new(role == .server ? 1 : 0, key, identity) else {
            throw WinTLSError.contextFailed(String(cString: ptb_tls_last_error()))
        }
        raw = ctx
    }

    /// Test seam: lets a test build a context with an arbitrary key or identity (wrong-key and wrong-identity cases).
    init(key: [UInt8], identity: String, role: Role) throws {
        guard key.count == 32, let ctx = ptb_tls_ctx_new(role == .server ? 1 : 0, key, identity) else {
            throw WinTLSError.contextFailed(String(cString: ptb_tls_last_error()))
        }
        raw = ctx
    }

    deinit { ptb_tls_ctx_free(raw) }
}

/// One TLS connection over a non-blocking socket. Owned by the I/O thread only; not thread-safe.
/// The socket stays the caller's: `close()` sends close_notify but never closes it.
final class WinTLSSession {
    enum Step: Equatable { case done, wantRead, wantWrite, failed(String), closed }

    private let context: WinTLSContext  // outlives `raw`
    private var raw: OpaquePointer?
    private let setupError: String?

    init(context: WinTLSContext, socket: UInt) {
        self.context = context
        raw = ptb_tls_new(context.raw, socket)
        setupError = raw == nil ? String(cString: ptb_tls_last_error()) : nil
    }

    deinit { close() }

    private static func step(_ code: Int32) -> Step {
        switch code {
        case Int32(PTB_TLS_OK): return .done
        case Int32(PTB_TLS_WANT_READ): return .wantRead
        case Int32(PTB_TLS_WANT_WRITE): return .wantWrite
        case Int32(PTB_TLS_CLOSED): return .closed
        default: return .failed(String(cString: ptb_tls_last_error()))
        }
    }

    private var unusable: Step { .failed(setupError ?? "TLS session closed") }

    func handshake() -> Step {
        guard let raw else { return unusable }
        return Self.step(ptb_tls_handshake(raw))
    }

    /// Up to `max` bytes. `(data, .done)` on bytes; `(nil, step)` otherwise.
    func read(max: Int) -> (Data?, Step) {
        guard let raw else { return (nil, unusable) }
        guard max > 0 else { return (nil, .failed("read of zero bytes")) }
        var buf = [UInt8](repeating: 0, count: max)
        let n = ptb_tls_read(raw, &buf, Int32(max))
        if n > 0 { return (Data(buf[0..<Int(n)]), .done) }
        return (nil, Self.step(n))
    }

    /// `written` bytes accepted (possibly fewer than `d.count`); on `.wantRead`/`.wantWrite` nothing was taken.
    func write(_ d: Data) -> (written: Int, Step) {
        guard let raw else { return (0, unusable) }
        if d.isEmpty { return (0, .done) }
        let bytes = [UInt8](d.prefix(Int(Int32.max)))
        let n = ptb_tls_write(raw, bytes, Int32(bytes.count))
        if n > 0 { return (Int(n), .done) }
        return (0, Self.step(n))
    }

    /// Decrypted bytes buffered inside OpenSSL; readable even when the socket is quiet.
    var pending: Int { raw.map { Int(ptb_tls_pending($0)) } ?? 0 }

    var cipher: String? { raw.flatMap { ptb_tls_cipher($0) }.map { String(cString: $0) } }
    var version: String? { raw.flatMap { ptb_tls_version_name($0) }.map { String(cString: $0) } }

    func close() {
        guard let r = raw else { return }
        raw = nil
        ptb_tls_close(r)
    }
}

enum WinTLS {
    /// OpenSSL's HMAC-SHA256, exposed so a test can cross-check the key derivation against Swift Crypto.
    static func hmacSHA256(key: Data, message: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: 32)
        let k = [UInt8](key), m = [UInt8](message)
        guard ptb_tls_hmac_sha256(k, k.count, m, m.count, &out) == 0 else { return nil }
        return Data(out)
    }
}
#endif
