import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension TeamCode {
    /// Eight hex digits of SHA-256 over the derived TLS-PSK key (`pskKey`). The Windows `--team-probe` prints it and
    /// `scripts/team-interop-check.sh --fingerprint` computes it on a Mac, so two machines can tell whether they hold
    /// the same key without either showing the code or the key.
    var keyFingerprint: String {
        let key = pskKey.withUnsafeBytes { Data($0) }
        return SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
