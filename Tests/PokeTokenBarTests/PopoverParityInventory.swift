import Foundation

/// The parity inventory (stage 7, D9): every function of the Mac popover with its Windows tier and status, and every
/// string, model member, setting, SF Symbol and source symbol mapped to one of those entries. The data lives in
/// `Tests/PopoverParity/` (outside the test target, so the Windows build never sees it) and is read through `#filePath`
/// on both systems. `PopoverParityScanTests` (Mac-side) holds it to the Mac sources; later tasks read it from here
/// (`PopoverParity.load().sfSymbols` for the Windows glyph table, the entries to flip `pending` to `done`).
enum PopoverParity {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PopoverParity", isDirectory: true)

    enum Tier: String, Equatable { case one = "1", two = "2", three = "3", none = "-" }

    enum Status: Equatable {
        /// A later task (`T<task>`) builds it.
        case pending(task: Int)
        /// Shipped in `path` (relative to `Sources/PokeTokenBar`).
        case done(path: String)
        /// An earlier stage does it outside the popover, in `path`.
        case elsewhere(path: String, note: String)
        case notApplicable(reason: String)
    }

    struct Entry: Equatable {
        var id: String
        var tier: Tier
        var status: Status
        var macFiles: [String]
        var function: String
    }

    /// A row's own status, when it is not the entry's.
    enum RowStatus: Equatable {
        /// The Mac string names a Mac thing; the entry cannot ship until it is `replaced`.
        case replace(why: String)
        /// The Windows popover shows this `L` member instead.
        case replaced(by: String)
        case notApplicable(reason: String)
    }

    struct Row: Equatable {
        var name: String
        var entry: String
        var status: RowStatus?
    }

    /// A shared twin of Mac logic. With `renames`, the two bodies must read the same once renamed; with a `pin` (for a
    /// Mac body that cannot read as its twin, such as a SwiftUI view body), the Mac body must still hash to the pin.
    struct Twin: Equatable {
        var mac: String
        var shared: String
        var renames: [String: String]
        var pin: String? = nil
    }

    struct Inventory: Equatable {
        var entries: [Entry] = []
        /// Mac files and symbols (`file` or `file#Type.member`).
        var code: [Row] = []
        /// `L` members by name, literals in double quotes.
        var strings: [Row] = []
        var members: [Row] = []
        var settings: [Row] = []
        var sfSymbols: [Row] = []
        var twins: [Twin] = []

        func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    }

    struct ParseError: Error, CustomStringConvertible {
        var file: String
        var line: Int
        var message: String
        var description: String { "\(file):\(line): \(message)" }
    }

    static func load(directory: URL = directory) throws -> Inventory {
        func read(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        return try parse(inventory: read("inventory.txt"), strings: read("strings.txt"), members: read("members.txt"),
                         settings: read("settings.txt"), sfSymbols: read("sf-symbols.txt"), twins: read("twins.txt"))
    }

    /// Data lines (blank lines and `#` comment lines dropped, CR tolerated) split on ` | ` (the last field keeps any
    /// further ` | `).
    static func lines(_ text: String) -> [(line: Int, fields: [String])] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return (index + 1, trimmed.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    static func parse(inventory: String, strings: String, members: String, settings: String, sfSymbols: String,
                      twins: String) throws -> Inventory {
        var out = Inventory()
        var section = ""
        for (line, fields) in lines(inventory) {
            if fields.count == 1, fields[0].hasPrefix("["), fields[0].hasSuffix("]") { section = fields[0]; continue }
            switch section {
            case "[entries]":
                guard fields.count >= 5 else { throw ParseError(file: "inventory.txt", line: line, message: "an entry has 5 fields") }
                guard let tier = Tier(rawValue: fields[1]) else {
                    throw ParseError(file: "inventory.txt", line: line, message: "tier \(fields[1]) is not 1, 2, 3 or -")
                }
                guard let status = parseStatus(fields[2]) else {
                    throw ParseError(file: "inventory.txt", line: line, message: "status \(fields[2]) is not pending T<n> / done <file> / elsewhere <file>: <note> / n/a: <reason>")
                }
                out.entries.append(Entry(id: fields[0], tier: tier, status: status,
                                         macFiles: fields[3].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                         function: fields[4...].joined(separator: " | ")))
            case "[code]":
                out.code.append(try row(fields, file: "inventory.txt", line: line))
            default:
                throw ParseError(file: "inventory.txt", line: line, message: "a row outside [entries] / [code]")
            }
        }
        out.strings = try lines(strings).map { try row($0.fields, file: "strings.txt", line: $0.line) }
        out.members = try lines(members).map { try row($0.fields, file: "members.txt", line: $0.line) }
        out.settings = try lines(settings).map { try row($0.fields, file: "settings.txt", line: $0.line) }
        out.sfSymbols = try lines(sfSymbols).map { try row($0.fields, file: "sf-symbols.txt", line: $0.line) }
        out.twins = try lines(twins).map { line, fields in
            guard fields.count >= 2 else { throw ParseError(file: "twins.txt", line: line, message: "a twin names the Mac and the shared symbol") }
            let third = fields.count > 2 ? fields[2] : ""
            if third.hasPrefix("pin ") {
                let pin = String(third.dropFirst(4))
                guard pin.count == 16, pin.allSatisfy(\.isHexDigit) else {
                    throw ParseError(file: "twins.txt", line: line, message: "a pin is 16 hex digits")
                }
                return Twin(mac: fields[0], shared: fields[1], renames: [:], pin: pin)
            }
            var renames: [String: String] = [:]
            for pair in third.components(separatedBy: ",") where pair.contains("=") {
                let p = pair.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                renames[p[0]] = p[1]
            }
            return Twin(mac: fields[0], shared: fields[1], renames: renames)
        }
        return out
    }

    static func parseStatus(_ text: String) -> Status? {
        if text.hasPrefix("pending T"), let task = Int(text.dropFirst("pending T".count)) { return .pending(task: task) }
        if text.hasPrefix("done "), !text.dropFirst(5).isEmpty { return .done(path: String(text.dropFirst(5))) }
        if text.hasPrefix("elsewhere "), let colon = text.firstIndex(of: ":") {
            let path = text[text.index(text.startIndex, offsetBy: "elsewhere ".count)..<colon]
            return path.isEmpty ? nil : .elsewhere(path: String(path), note: text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if text.hasPrefix("n/a: "), !text.dropFirst(5).isEmpty { return .notApplicable(reason: String(text.dropFirst(5))) }
        return nil
    }

    static func parseRowStatus(_ text: String) -> RowStatus? {
        if text.hasPrefix("replace: "), !text.dropFirst(9).isEmpty { return .replace(why: String(text.dropFirst(9))) }
        if text.hasPrefix("replaced: "), !text.dropFirst(10).isEmpty { return .replaced(by: String(text.dropFirst(10))) }
        if text.hasPrefix("n/a: "), !text.dropFirst(5).isEmpty { return .notApplicable(reason: String(text.dropFirst(5))) }
        return nil
    }

    private static func row(_ fields: [String], file: String, line: Int) throws -> Row {
        guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
            throw ParseError(file: file, line: line, message: "a row is `name | entry [| status]`")
        }
        var status: RowStatus?
        if fields.count > 2 {
            let text = fields[2...].joined(separator: " | ")
            guard let s = parseRowStatus(text) else {
                throw ParseError(file: file, line: line, message: "row status \(text) is not replace: / replaced: / n/a:")
            }
            status = s
        }
        return Row(name: fields[0], entry: fields[1], status: status)
    }

    // MARK: - counts

    /// `PARITY: 0 missing, 0 stale · entries 1: 12 pending, 1 done · …` for the scan's log line.
    static func summary(_ inventory: Inventory, missing: Int, stale: Int) -> String {
        var parts: [String] = []
        for tier in [Tier.one, .two, .three, .none] {
            let entries = inventory.entries.filter { $0.tier == tier }
            var byStatus: [String: Int] = [:]
            for e in entries {
                switch e.status {
                case .pending: byStatus["pending", default: 0] += 1
                case .done: byStatus["done", default: 0] += 1
                case .elsewhere: byStatus["elsewhere", default: 0] += 1
                case .notApplicable: byStatus["n/a", default: 0] += 1
                }
            }
            let detail = ["pending", "done", "elsewhere", "n/a"].compactMap { k in byStatus[k].map { "\($0) \(k)" } }.joined(separator: ", ")
            parts.append("tier \(tier.rawValue): \(entries.count) (\(detail))")
        }
        let replace = inventory.strings.filter { if case .replace = $0.status { return true } else { return false } }.count
        return "PARITY: \(missing) missing, \(stale) stale · \(inventory.entries.count) entries · " + parts.joined(separator: " · ")
            + " · rows: \(inventory.code.count) code, \(inventory.strings.count) strings (\(replace) to replace), "
            + "\(inventory.members.count) members, \(inventory.settings.count) settings, \(inventory.sfSymbols.count) SF Symbols, "
            + "\(inventory.twins.count) twins"
    }
}
