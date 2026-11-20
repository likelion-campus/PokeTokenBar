import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum UsageReportConfig {
    static let endpoint = URL(string: "https://script.google.com/macros/s/AKfycbxyIn2tAUC_fE_HXqLA8VpGLSPwepUZ5_QRujhGot7wF6oyeaheIZY3O8jXgVbnNSfm/exec")!
    static let token = "996c41db62671eaf62a86cf3e18202ee"   // tools/usage-sheet/src/00_config.js SHARED_TOKEN; public by design
    static let version = 1
    static let baseInterval: TimeInterval = 3600            // spec 6: about once an hour
    static let spreadWindow: TimeInterval = 600             // per-member offset in 0..<600 s
    static let presenceCap: TimeInterval = 3900             // longest gap one presence record may count
    static let retentionDays = 45                           // ledger keeps 45 days (> the 21 sent)
    static let maxLimits = 16                               // CONTRACT: limits array holds at most 16
    static let requestTimeout: TimeInterval = 30
}

/// The JSON body of one report, exactly as `tools/usage-sheet/CONTRACT.md` defines it.
struct UsageReportBody: Encodable, Equatable {
    struct Member: Encodable, Equatable {
        var id: String
        var secret: String
        var nickname: String
        var appVersion: String
        var platform: String
    }

    struct Tool: Encodable, Equatable {
        var tool: String
        var input: Int
        var output: Int
        var cacheWrite: Int
        var cacheRead: Int
    }

    struct Day: Encodable, Equatable {
        var date: String
        var team: String
        var teamLabel: String?
        var tools: [Tool]
    }

    struct Limit: Encodable, Equatable {
        var tool: String
        var account: String
        var domain: String
        var plan: String
        var usedPercent: Double
        var resetsAt: String
        var readAt: String
        var team: String
    }

    var v: Int
    var token: String
    var member: Member
    var days: [Day]
    var limits: [Limit]

    static func encoded(_ body: UsageReportBody) throws -> Data {
        try JSONEncoder().encode(body)
    }

    /// First 16 hex characters of the SHA-256 of the day encoded with sorted keys.
    static func fingerprint(_ day: Day) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain strings and ints cannot fail.
        let data = (try? encoder.encode(day)) ?? Data()
        return UsageReportIDs.hex16(Data(SHA256.hash(data: data)))
    }
}

enum UsageReportResponse: Equatable {
    case accepted(days: Int, limits: Int, dropped: Int)
    case rejected(String)
    case notJSON

    static func parse(_ data: Data) -> UsageReportResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else { return .notJSON }
        if !ok { return .rejected(object["error"] as? String ?? "unknown") }
        guard let accepted = object["accepted"] as? [String: Any],
              let days = accepted["days"] as? Int,
              let limits = accepted["limits"] as? Int,
              let dropped = object["dropped"] as? Int else { return .notJSON }
        return .accepted(days: days, limits: limits, dropped: dropped)
    }
}

enum UsageReportIDs {
    static func hex16(_ bytes: Data) -> String {
        bytes.prefix(8).map { byte in
            let h = String(byte, radix: 16)
            return h.count == 1 ? "0" + h : h
        }.joined()
    }

    /// One-way account ID: a hash of the lowercased email, or the member and local IDs when no email is known.
    static func account(email: String?, memberID: String, localAccountID: String) -> String {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "m_" + memberID + "_" + localAccountID }
        return "e_" + hex16(Data(SHA256.hash(data: Data(trimmed.lowercased().utf8))))
    }

    static func domain(email: String?) -> String {
        guard let email, let at = email.lastIndex(of: "@") else { return "" }
        return email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isoUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}

extension TeamCode {
    /// A stable one-way team ID. It is a different HMAC label from `pskKey`, so it never reveals the PSK.
    var usageTeamID: String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("poketokenbar.team.usage-id.v1".utf8),
            using: SymmetricKey(data: Data(normalized.utf8)))
        return "t_" + UsageReportIDs.hex16(Data(mac))
    }
}
