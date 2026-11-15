import Foundation

/// The parity scan's rules (stage 7, D9) as pure functions over an inventory and extracted names, so each is tested on
/// synthetic input on both systems. Every finding says what to do.
enum PopoverParityRules {
    typealias Row = PopoverParity.Row

    /// Rules 1 and 2 for one data file: every extracted name has exactly one row, and every row names something extracted.
    static func coverage(file: String, extracted: [String: Set<String>], rows: [Row]) -> [String] {
        var out: [String] = []
        var seen: [String: Int] = [:]
        for r in rows { seen[r.name, default: 0] += 1 }
        for (name, count) in seen.sorted(by: { $0.key < $1.key }) where count > 1 {
            out.append("\(file): `\(name)` has \(count) rows: keep one")
        }
        for name in extracted.keys.sorted() where seen[name] == nil {
            let sites = extracted[name]!.sorted().prefix(3).joined(separator: ", ")
            out.append("\(file): `\(name)` (in \(sites)) has no row: add `\(name) | <entry id>` naming the inventory entry that shows it on the Mac (add an entry to inventory.txt if none fits), then decide what Windows does")
        }
        for name in seen.keys.sorted() where extracted[name] == nil {
            out.append("\(file): the row `\(name)` names nothing the Mac popover has any more: delete it, or fix the name if it was renamed")
        }
        return out
    }

    /// Rule 3: the entries and rows are well formed and point at things that exist.
    static func consistency(_ inventory: PopoverParity.Inventory, macFiles: Set<String>, pathExists: (String) -> Bool) -> [String] {
        var out: [String] = []
        var ids: [String: Int] = [:]
        for e in inventory.entries { ids[e.id, default: 0] += 1 }
        for (id, count) in ids where count > 1 { out.append("inventory.txt: the entry \(id) is defined \(count) times") }
        for e in inventory.entries {
            switch (e.tier, e.status) {
            case (.none, .notApplicable), (.one, .elsewhere), (.two, .elsewhere), (.three, .elsewhere): break
            case (.none, _): out.append("inventory.txt: \(e.id) has tier - but is not n/a: give it a tier, or say why it does not apply")
            case (_, .notApplicable): out.append("inventory.txt: \(e.id) is n/a but has tier \(e.tier.rawValue): use tier -")
            case (_, .pending(let task)) where !(2...24).contains(task):
                out.append("inventory.txt: \(e.id) is pending T\(task), which is not a stage 7 task (2…24)")
            default: break
            }
            switch e.status {
            case .done(let path), .elsewhere(let path, _):
                if !pathExists(path) { out.append("inventory.txt: \(e.id) points at \(path), which does not exist") }
            default: break
            }
            for f in e.macFiles where !macFiles.contains(f) {
                out.append("inventory.txt: \(e.id) names the Mac file \(f), which is not a popover file")
            }
        }
        let rowFiles: [(String, [Row])] = [("inventory.txt [code]", inventory.code), ("strings.txt", inventory.strings),
                                           ("members.txt", inventory.members), ("settings.txt", inventory.settings),
                                           ("sf-symbols.txt", inventory.sfSymbols)]
        for (file, rows) in rowFiles {
            for r in rows where ids[r.entry] == nil {
                out.append("\(file): `\(r.name)` points at the entry \(r.entry), which inventory.txt does not define")
            }
            if file != "strings.txt" {
                for r in rows {
                    if case .replace = r.status { out.append("\(file): `\(r.name)` uses replace:, which only strings take") }
                    if case .replaced = r.status { out.append("\(file): `\(r.name)` uses replaced:, which only strings take") }
                }
            }
        }
        return out
    }

    /// Rule 4: a shipped entry's strings and members are in the Windows popover. A string to `replace` must have become
    /// `replaced: <member>`, and that member must exist and be used there. Names are matched as whole words, so a
    /// declaration (a twin's) counts as accounted for.
    static func doneEntries(_ inventory: PopoverParity.Inventory, windowsSource: String, lMembers: Set<String>) -> [String] {
        let done = Set(inventory.entries.compactMap { e -> String? in if case .done = e.status { return e.id } else { return nil } })
        var out: [String] = []
        func used(_ word: String) -> Bool { containsWord(windowsSource, word) }
        for r in inventory.strings where done.contains(r.entry) {
            let isLiteral = r.name.hasPrefix("\"")
            switch r.status {
            case nil:
                let present = isLiteral ? windowsSource.contains(r.name) : used(r.name)
                if !present { out.append("strings.txt: \(r.entry) is done but the Windows popover never shows `\(r.name)`: use it there, or give the row a status") }
            case .replace(let why)?:
                out.append("strings.txt: \(r.entry) is done but `\(r.name)` still says replace: (\(why)): add a win… member in Platform/WindowsPopoverStrings.swift and write `replaced: <member>`")
            case .replaced(let by)?:
                if !lMembers.contains(by) { out.append("strings.txt: `\(r.name)` is replaced by `\(by)`, which no extension L declares") }
                else if !used(by) { out.append("strings.txt: `\(r.name)` is replaced by `\(by)`, which the Windows popover never shows") }
            case .notApplicable?:
                break
            }
        }
        for r in inventory.members where done.contains(r.entry) && r.status == nil {
            let member = r.name.components(separatedBy: ".").last ?? r.name
            if !used(member) { out.append("members.txt: \(r.entry) is done but the Windows popover never uses `\(r.name)`: use it there, or give the row an n/a reason") }
        }
        return out
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: word, range: search) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            func isIdentifier(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
            if !isIdentifier(before) && !isIdentifier(after) { return true }
            search = r.upperBound..<text.endIndex
        }
        return false
    }

    // MARK: - twins (rule 5)

    /// The braces' content of the type `name` declared in `text` (comments dropped, string literals kept), or nil.
    static func body(ofType name: String, in text: String) -> String? {
        let lexed = PopoverParityExtractor.lex(text)
        var code = lexed.code
        let original = Array(text.utf8)
        for l in lexed.literals { for i in l.start..<l.end { code[i] = original[i] } }   // put the literals back
        guard let declaration = PopoverParityExtractor.declarations(in: lexed.code).first(where: { $0.kind == .type && $0.name == name }),
              let range = declaration.body, let open = code[range].firstIndex(of: 123) else { return nil }
        return String(decoding: code[(open + 1)..<(range.upperBound - 1)], as: UTF8.self)
    }

    /// White space collapsed to single spaces and `renames` applied as whole words.
    static func normalized(_ body: String, renames: [String: String]) -> String {
        var words = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for (from, to) in renames.sorted(by: { $0.key.count > $1.key.count }) {
            words = replacingWord(from, with: to, in: words)
        }
        return words
    }

    private static func replacingWord(_ word: String, with replacement: String, in text: String) -> String {
        var out = ""
        var rest = text[...]
        while let r = rest.range(of: word) {
            let before = r.lowerBound == rest.startIndex ? out.last : rest[rest.index(before: r.lowerBound)]
            let after = r.upperBound == rest.endIndex ? nil : rest[r.upperBound]
            func isIdentifier(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
            out += rest[..<r.lowerBound]
            out += !isIdentifier(before) && !isIdentifier(after) ? replacement : word
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    /// `file#Type` of a twin row, read through `read` (a path relative to `Sources/PokeTokenBar`).
    static func twins(_ inventory: PopoverParity.Inventory, read: (String) -> String?) -> [String] {
        var out: [String] = []
        for twin in inventory.twins {
            let sides = [twin.mac, twin.shared].map { $0.components(separatedBy: "#") }
            guard sides.allSatisfy({ $0.count == 2 }) else { out.append("twins.txt: write each side as file#Type"); continue }
            guard let macText = read(sides[0][0]), let sharedText = read(sides[1][0]) else {
                out.append("twins.txt: \(sides[0][0]) or \(sides[1][0]) does not exist"); continue
            }
            guard let mac = body(ofType: sides[0][1], in: macText) else { out.append("twins.txt: \(twin.mac) is not declared"); continue }
            guard let shared = body(ofType: sides[1][1], in: sharedText) else { out.append("twins.txt: \(twin.shared) is not declared"); continue }
            let a = normalized(mac, renames: twin.renames), b = normalized(shared, renames: [:])
            if a != b {
                let common = zip(a, b).prefix { $0 == $1 }.count
                let at = a.index(a.startIndex, offsetBy: max(0, common - 40))
                out.append("twins.txt: \(twin.shared) no longer matches \(twin.mac) (after the renames). Copy the Mac change into the twin and its equivalence test. They part at: …\(a[at...].prefix(120))")
            }
        }
        return out
    }
}
