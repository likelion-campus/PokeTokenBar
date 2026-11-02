import Foundation
import CryptoKit

/// 팀 공유 비밀: 128비트 난수를 RFC 4648 base32(26자)로 표기한다. TLS-PSK 키 유도의 입력.
struct TeamCode: Equatable, Sendable {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// 26자 base32 대문자.
    let normalized: String

    private init(normalized: String) { self.normalized = normalized }

    /// `PTB-XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX` (5-5-5-5-6).
    var display: String {
        let c = Array(normalized)
        let groups = [0..<5, 5..<10, 10..<15, 15..<20, 20..<26].map { String(c[$0]) }
        return "PTB-" + groups.joined(separator: "-")
    }

    static func generate<R: RandomNumberGenerator>(using rng: inout R) -> TeamCode {
        let hi = rng.next(), lo = rng.next()
        var bytes = [UInt8]()
        for word in [hi, lo] { for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) } }
        var out = ""
        var buffer: UInt32 = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b); bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)]); bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }   // 128비트 → 마지막 2비트 패딩 0
        return TeamCode(normalized: out)
    }

    init?(parsing input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("PTB"), let sep = s.dropFirst(3).first, sep == "-" || sep.isWhitespace { s.removeFirst(3) }
        s.removeAll { $0 == "-" || $0.isWhitespace }
        guard s.count == 26, s.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
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
