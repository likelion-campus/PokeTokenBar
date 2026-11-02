import Foundation
import CryptoKit

/// 팀 공유 비밀: 60비트 난수를 RFC 4648 base32(12자)로 표기한다. TLS-PSK 키 유도의 입력.
/// 같은 와이파이에서 주고받는 데이터를 잡으면 코드를 대입해 볼 수 있으므로 이보다 줄이지 않는다.
/// 예전에 만든 26자(128비트) 코드도 그대로 받는다.
struct TeamCode: Equatable, Sendable {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    static let length = 12
    static let legacyLength = 26

    /// base32 대문자. 새 코드는 12자, 예전 코드는 26자.
    let normalized: String

    private init(normalized: String) { self.normalized = normalized }

    /// 새 코드는 `PTB-XXXX-XXXX-XXXX`, 예전 코드는 `PTB-XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX`.
    var display: String {
        let c = Array(normalized)
        let sizes = c.count == Self.legacyLength ? [5, 5, 5, 5, 6] : [4, 4, 4]
        var groups: [String] = [], start = 0
        for size in sizes where start < c.count {
            groups.append(String(c[start..<min(start + size, c.count)]))
            start += size
        }
        return "PTB-" + groups.joined(separator: "-")
    }

    static func generate<R: RandomNumberGenerator>(using rng: inout R) -> TeamCode {
        let bits = rng.next() >> 4   // 60비트 = base32 12자
        let out = (0..<length).map { alphabet[Int((bits >> UInt64(5 * (length - 1 - $0))) & 31)] }
        return TeamCode(normalized: String(out))
    }

    init?(parsing input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("PTB"), let sep = s.dropFirst(3).first, sep == "-" || sep.isWhitespace { s.removeFirst(3) }
        s.removeAll { $0 == "-" || $0.isWhitespace }
        guard s.count == Self.length || s.count == Self.legacyLength,
              s.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.normalized = s
    }

    var pskKey: SymmetricKey {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("poketokenbar.team.psk.v1".utf8),
            using: SymmetricKey(data: Data(normalized.utf8)))
        return SymmetricKey(data: Data(mac))
    }

    static let pskIdentity = Data("ptb-team-v1".utf8)
}
