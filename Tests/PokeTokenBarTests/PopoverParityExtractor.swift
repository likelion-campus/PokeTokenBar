import Foundation

/// Reads Swift source as text and lists what the parity scan holds the inventory to (stage 7, D9). Pure text work, so
/// its tests run on both systems; the scan that points it at the Mac popover is `PopoverParityScanTests` (Mac-side).
///
/// The signals, and why each is stable under refactors:
/// - **files**: every Swift file of the popover. A new file is a new place for behaviour.
/// - **symbols**: every type, `func` and computed `var` declared in a type, an extension or at file level
///   (`file#Type.member`; nested functions and locals are part of their function). Renaming one fails twice (stale + missing),
///   which is a cheap edit; moving code inside a function does not fail.
/// - **strings**: every `L` member the files reference (`l.x`, `store.l.x`, `L(.ko).x`, inside interpolations too), filtered
///   to the members `struct L` / `extension L` declare, plus the string literals passed to a text-showing call. A new label
///   is the most reliable sign of a new control.
/// - **members**: every `receiver.member` (and `$receiver.member`) where the receiver is declared in the same file as one of
///   the popover's models. Bindings, reads and action targets (`Button { store.refresh() }`) all pass through here.
/// - **settings**: every UserDefaults key a store or a popover file reads or writes, resolved to a literal or a constant.
/// - **sfSymbols**: every literal passed as `systemName:`, `systemImage:` or `systemSymbolName:`.
/// Counting controls (`Toggle(`, `Picker(`) was left out: a control moves between helpers on every refactor, while its
/// label (strings) and its target (members) are what it means.
enum PopoverParityExtractor {
    struct Literal: Equatable { var start: Int; var end: Int; var body: String }

    /// Source with comments removed and string-literal characters blanked (newlines kept), so braces and names can be
    /// read by position; the code inside `\( … )` interpolations stays. Same length as the input, in UTF-8 bytes.
    struct Lexed {
        var code: [UInt8]
        var literals: [Literal]
    }

    static func lex(_ text: String) -> Lexed {
        let src = Array(text.utf8)
        var out = [UInt8](repeating: 32, count: src.count)
        var literals: [Literal] = []
        let n = src.count
        func at(_ i: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            guard i + u.count <= n else { return false }
            for k in 0..<u.count where src[i + k] != u[k] { return false }
            return true
        }
        func keep(_ i: Int) { out[i] = src[i] }
        func newlineOnly(_ i: Int) { if src[i] == 10 { out[i] = 10 } }

        // Returns the index after the closing `)` when `inInterpolation`, else n.
        func code(from start: Int, inInterpolation: Bool) -> Int {
            var i = start, depth = 0
            while i < n {
                if at(i, "//") {
                    while i < n, src[i] != 10 { i += 1 }
                    continue
                }
                if at(i, "/*") {
                    var d = 1
                    i += 2
                    while i < n, d > 0 {
                        if at(i, "/*") { d += 1; i += 2 } else if at(i, "*/") { d -= 1; i += 2 } else { newlineOnly(i); i += 1 }
                    }
                    continue
                }
                let c = src[i]
                if c == 34 || (c == 35 && i + 1 < n && (src[i + 1] == 35 || src[i + 1] == 34)) {   // " or #
                    var k = i, hashes = 0
                    while k < n, src[k] == 35 { hashes += 1; k += 1 }
                    if k < n, src[k] == 34 { i = string(at: i, quote: k, hashes: hashes); continue }
                }
                if inInterpolation {
                    if c == 40 { depth += 1 }
                    if c == 41 {
                        if depth == 0 { keep(i); return i + 1 }
                        depth -= 1
                    }
                }
                keep(i)
                i += 1
            }
            return i
        }

        func string(at start: Int, quote: Int, hashes: Int) -> Int {
            let multi = at(quote, "\"\"\"")
            let qlen = multi ? 3 : 1
            for p in start..<(quote + qlen) { keep(p) }
            var j = quote + qlen
            let bodyStart = j
            let close = Array((multi ? "\"\"\"" : "\"").utf8) + [UInt8](repeating: 35, count: hashes)
            func closesHere(_ j: Int) -> Bool {
                guard j + close.count <= n else { return false }
                for k in 0..<close.count where src[j + k] != close[k] { return false }
                return true
            }
            while j < n {
                if src[j] == 92 {   // backslash
                    var after = j + 1, h = 0
                    while h < hashes, after < n, src[after] == 35 { h += 1; after += 1 }
                    if h == hashes, after < n {
                        if src[after] == 40 { keep(after); j = code(from: after + 1, inInterpolation: true); continue }
                        j = after + 1
                        continue
                    }
                }
                if closesHere(j) { break }
                if !multi, src[j] == 10 { break }
                newlineOnly(j)
                j += 1
            }
            let end = min(n, j + close.count)
            for p in j..<end { keep(p) }
            literals.append(Literal(start: start, end: end, body: String(decoding: src[bodyStart..<min(j, n)], as: UTF8.self)))
            return end
        }

        _ = code(from: 0, inInterpolation: false)
        return Lexed(code: out, literals: literals)
    }

    // MARK: - declarations

    struct Declaration: Equatable {
        /// `extension` bodies are kept only to resolve `Self` and to find the enclosing symbol; they are not symbols.
        enum Kind: Equatable { case type, extensionBody, function, computedVar }
        var kind: Kind
        /// `Type.member`, `Type`, or a file-level `function`.
        var name: String
        /// The body's braces, in byte offsets (nil when the declaration has no body).
        var body: Range<Int>?
    }

    private static let declarationKeywords: Set<String> = ["struct", "class", "enum", "actor", "protocol", "extension", "func",
                                                           "var", "let", "init", "deinit", "subscript", "case", "typealias"]

    private static func isIdentifierByte(_ c: UInt8) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
    }

    private static func word(_ code: [UInt8], at i: Int) -> (String, Int)? {
        guard i < code.count, isIdentifierByte(code[i]), !(code[i] >= 48 && code[i] <= 57) else { return nil }
        var j = i
        while j < code.count, isIdentifierByte(code[j]) { j += 1 }
        return (String(decoding: code[i..<j], as: UTF8.self), j)
    }

    private static func skipSpaces(_ code: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < code.count, code[j] == 32 || code[j] == 10 || code[j] == 9 || code[j] == 13 { j += 1 }
        return j
    }

    /// Types, functions and computed vars whose enclosing scope is a type, an extension or the file.
    static func declarations(in code: [UInt8]) -> [Declaration] {
        enum ScopeKind { case type(String), function, accessor, other }
        struct Scope { var kind: ScopeKind; var depth: Int; var index: Int? }
        struct Pending { var kind: ScopeKind; var paren: Int; var index: Int? }
        var out: [Declaration] = []
        var stack: [Scope] = []
        var depth = 0, paren = 0
        var pending: Pending?
        let n = code.count

        func owner() -> String? {   // nil: inside a function or accessor (not recorded); "": file level
            for s in stack.reversed() {
                switch s.kind {
                case .type(let name): return name
                case .function, .accessor, .other: return nil
                }
            }
            return ""
        }

        var i = 0
        while i < n {
            let c = code[i]
            if c == 40 || c == 91 { paren += 1; i += 1; continue }
            if c == 41 || c == 93 { paren -= 1; i += 1; continue }
            if c == 123 {   // {
                depth += 1
                if let p = pending, p.paren == paren {
                    stack.append(Scope(kind: p.kind, depth: depth, index: p.index))
                    pending = nil
                } else {
                    stack.append(Scope(kind: .other, depth: depth, index: nil))
                }
                i += 1
                continue
            }
            if c == 125 {   // }
                if let top = stack.last, top.depth == depth {
                    stack.removeLast()
                    if let index = top.index { out[index].body = out[index].body.map { $0.lowerBound..<(i + 1) } }
                }
                depth -= 1
                i += 1
                continue
            }
            let boundary = i == 0 || !(isIdentifierByte(code[i - 1]) || code[i - 1] == 46 || code[i - 1] == 36 || code[i - 1] == 64 || code[i - 1] == 35)
            guard boundary, let (w, end) = word(code, at: i) else { i += 1; continue }
            // A declaration without a body (a protocol requirement) leaves `pending` set: the next declaration at the same
            // depth ends it.
            if let p = pending, p.paren == paren, declarationKeywords.contains(w) { pending = nil }
            guard pending == nil else { i = end; continue }
            let o = owner()
            switch w {
            case "struct", "class", "enum", "actor", "protocol", "extension":
                let s = skipSpaces(code, end)
                var j = s
                while j < n, isIdentifierByte(code[j]) || code[j] == 46 { j += 1 }
                let name = String(decoding: code[s..<j], as: UTF8.self)
                if name.isEmpty || ["func", "var", "let"].contains(name) { i = end; continue }   // `class func`, `class var`
                if let o {
                    let qualified = o.isEmpty || w == "extension" ? name : o + "." + name
                    out.append(Declaration(kind: w == "extension" ? .extensionBody : .type, name: qualified, body: i..<i))
                    pending = Pending(kind: .type(qualified), paren: paren, index: out.count - 1)
                } else {
                    pending = Pending(kind: .other, paren: paren, index: nil)
                }
                i = j
                continue
            case "func":
                let s = skipSpaces(code, end)
                var j = s
                while j < n, code[j] != 40, code[j] != 60, code[j] != 32, code[j] != 10 { j += 1 }   // up to ( < space
                let name = String(decoding: code[s..<j], as: UTF8.self)
                var index: Int?
                if let o, !name.isEmpty {
                    out.append(Declaration(kind: .function, name: o.isEmpty ? name : o + "." + name, body: i..<i))
                    index = out.count - 1
                }
                pending = Pending(kind: .function, paren: paren, index: index)
                i = j
                continue
            case "init", "deinit", "subscript":
                pending = Pending(kind: .function, paren: paren, index: nil)
            case "var":
                // `var name: Type {` with a body that is not didSet/willSet: a computed var.
                guard o != nil else { break }
                let s = skipSpaces(code, end)
                guard let (name, afterName) = word(code, at: s) else { break }
                var j = skipSpaces(code, afterName)
                guard j < n, code[j] == 58 else { break }   // :
                j += 1
                var d = 0
                while j < n {
                    let ch = code[j]
                    if ch == 40 || ch == 91 || ch == 60 { d += 1 }
                    if ch == 41 || ch == 93 || (ch == 62 && code[j - 1] != 45) { d -= 1 }   // `>` but not `->`
                    if d == 0 && (ch == 61 || ch == 10 || ch == 123) { break }   // = newline {
                    j += 1
                }
                guard j < n, code[j] == 123 else { break }
                let inner = skipSpaces(code, j + 1)
                if let (first, _) = word(code, at: inner), first == "didSet" || first == "willSet" { break }
                out.append(Declaration(kind: .computedVar, name: (o ?? "").isEmpty ? name : o! + "." + name, body: j..<j))
                pending = Pending(kind: .accessor, paren: paren, index: out.count - 1)
                i = j
                continue
            default:
                break
            }
            i = end
        }
        // A body range starts at the declaration and ends at its closing brace (set on pop).
        return out
    }

    /// The innermost declaration whose span holds `offset`, as `file#name`; the file alone at file level.
    static func enclosing(_ declarations: [Declaration], offset: Int, file: String) -> String {
        var best: Declaration?
        for d in declarations where d.kind != .extensionBody {
            guard let r = d.body, r.contains(offset) else { continue }
            if best == nil || r.count < best!.body!.count { best = d }
        }
        return best.map { "\(file)#\($0.name)" } ?? file
    }

    // MARK: - references

    /// Names declared at the top level of `struct L` and every `extension L` in `sources`.
    static func lMembers(in sources: [String]) -> Set<String> {
        var names = Set<String>()
        for text in sources {
            let code = lex(text).code
            var i = 0
            while let r = find(code, ["struct L", "extension L"], from: i) {
                i = r.upperBound
                guard r.upperBound < code.count, !isIdentifierByte(code[r.upperBound]),
                      r.lowerBound == 0 || !isIdentifierByte(code[r.lowerBound - 1]),
                      let open = code[r.upperBound...].firstIndex(of: 123) else { continue }
                var depth = 0, j = open
                while j < code.count {
                    if code[j] == 123 { depth += 1 }
                    if code[j] == 125 { depth -= 1; if depth == 0 { break } }
                    if depth == 1, let (w, end) = word(code, at: j), j == 0 || !isIdentifierByte(code[j - 1]) {
                        if (w == "var" || w == "func"), let (name, _) = word(code, at: skipSpaces(code, end)),
                           !precededByStatic(code, j) {
                            names.insert(name)
                        }
                        j = end
                        continue
                    }
                    j += 1
                }
                i = j
            }
        }
        return names
    }

    private static func precededByStatic(_ code: [UInt8], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, code[j] == 32 { j -= 1 }
        let start = max(0, j - 5)
        return j >= 5 && String(decoding: code[start...j], as: UTF8.self) == "static"
    }

    private static func find(_ code: [UInt8], _ needles: [String], from: Int) -> Range<Int>? {
        var best: Range<Int>?
        for needle in needles {
            let u = Array(needle.utf8)
            guard u.count <= code.count else { continue }
            var i = from
            while i + u.count <= code.count {
                if code[i] == u[0], Array(code[i..<(i + u.count)]) == u {
                    if best == nil || i < best!.lowerBound { best = i..<(i + u.count) }
                    break
                }
                i += 1
            }
        }
        return best
    }

    /// `(member, offset)` for every `l.member`, `<name>.l.member` and `L(…).member` in `code` whose member is in `known`.
    static func stringReferences(_ code: [UInt8], known: Set<String>) -> [(String, Int)] {
        var out: [(String, Int)] = []
        let n = code.count
        var i = 0
        while i < n {
            // `l` as a whole word (a receiver may precede it: `store.l`), or `L(` … `)`.
            var afterReceiver: Int?
            if code[i] == 108, i + 1 < n, !isIdentifierByte(code[i + 1]), i == 0 || !isIdentifierByte(code[i - 1]) {   // l
                afterReceiver = i + 1
            } else if code[i] == 76, i + 1 < n, code[i + 1] == 40, i == 0 || !(isIdentifierByte(code[i - 1]) || code[i - 1] == 46) {   // L(
                var d = 0, j = i + 1
                while j < n { if code[j] == 40 { d += 1 }; if code[j] == 41 { d -= 1; if d == 0 { break } }; j += 1 }
                afterReceiver = j + 1
            }
            if var j = afterReceiver {
                j = skipSpaces(code, j)
                if j < n, code[j] == 46, let (name, _) = word(code, at: skipSpaces(code, j + 1)), known.contains(name) {
                    out.append((name, i))
                }
            }
            i += 1
        }
        return out
    }

    /// The models whose members the scan follows.
    static let modelTypes: Set<String> = ["UsageStore", "CompanionStore", "UpdateChecker", "TeamSettings", "PopoverNavigation",
                                          "TeamFeedStore", "TeamSession", "TeamRuntime", "PlazaWindowController"]

    /// Receiver name → model type, from the declarations in this file (`@Environment(T.self) var x`, `let x: T`, `_ x: T`).
    static func receivers(_ code: [UInt8]) -> [String: String] {
        let text = String(decoding: code, as: UTF8.self)
        var out: [String: Set<String>] = [:]
        let patterns = [
            #"@Environment\(\s*([A-Z]\w*)\.self\s*\)\s*(?:private\s+)?var\s+(\w+)"#,
            #"(?:var|let)\s+(\w+)\s*:\s*([A-Z]\w*)(?![\w.<])"#,
            #"_\s+(\w+)\s*:\s*([A-Z]\w*)(?![\w.<])"#,
        ]
        for (k, pattern) in patterns.enumerated() {
            let regex = try! NSRegularExpression(pattern: pattern)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { continue }
                let (name, type) = k == 0 ? (String(text[b]), String(text[a])) : (String(text[a]), String(text[b]))
                if modelTypes.contains(type) { out[name, default: []].insert(type) }
            }
        }
        return out.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// `(Type.member, offset)` for every `receiver.member`, `$receiver.member` and `receiver?.member` of a model receiver.
    static func memberReferences(_ code: [UInt8]) -> [(String, Int)] {
        let known = receivers(code)
        var out: [(String, Int)] = []
        let n = code.count
        var i = 0
        while i < n {
            guard i == 0 || !(isIdentifierByte(code[i - 1]) || code[i - 1] == 46), let (name, end) = word(code, at: i) else {
                i += 1
                continue
            }
            if let type = known[name] {
                var j = end
                if j < n, code[j] == 63 { j += 1 }   // ?
                j = skipSpaces(code, j)
                if j < n, code[j] == 46, let (member, _) = word(code, at: skipSpaces(code, j + 1)), member != "l" {
                    out.append(("\(type).\(member)", i))
                }
            }
            i = end
        }
        return out
    }

    /// `(name, offset)` for every literal passed as `systemName:`, `systemImage:` or `systemSymbolName:` (each literal of a
    /// conditional expression counts).
    static func sfSymbols(_ lexed: Lexed) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for label in ["systemName:", "systemImage:", "systemSymbolName:"] {
            var from = 0
            while let r = find(lexed.code, [label], from: from) {
                from = r.upperBound
                guard r.lowerBound == 0 || !isIdentifierByte(lexed.code[r.lowerBound - 1]) else { continue }
                let end = argumentEnd(lexed.code, from: r.upperBound)
                for l in lexed.literals where l.start >= r.upperBound && l.end <= end + 1 { out.append((l.body, l.start)) }
            }
        }
        return out
    }

    /// The calls whose first argument is text the user reads.
    static let textCalls: Set<String> = ["Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Menu", "Picker",
                                         "help", "accessibilityLabel", "navigationTitle", "footerLink"]

    /// `(literal, offset)` for every literal with a letter in the first argument of a text call.
    static func uiLiterals(_ lexed: Lexed) -> [(String, Int)] {
        var out: [(String, Int)] = []
        let code = lexed.code
        let n = code.count
        var i = 0
        while i < n {
            guard i == 0 || !isIdentifierByte(code[i - 1]), let (name, end) = word(code, at: i) else { i += 1; continue }
            let open = skipSpaces(code, end)
            if textCalls.contains(name), open < n, code[open] == 40 {
                let close = argumentEnd(code, from: open + 1)
                for l in lexed.literals where l.start > open && l.end <= close + 1 && hasLetter(l.body) { out.append((l.body, l.start)) }
            }
            i = end
        }
        return out
    }

    private static func hasLetter(_ body: String) -> Bool {
        var text = body
        while let r = text.range(of: #"\\\([^)]*\)"#, options: .regularExpression) { text.removeSubrange(r) }
        return text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }

    /// The offset of the `,` or `)` that ends the argument starting at `from`.
    private static func argumentEnd(_ code: [UInt8], from: Int) -> Int {
        var j = from, d = 0
        while j < code.count {
            let c = code[j]
            if c == 40 || c == 91 || c == 123 { d += 1 }
            if c == 41 || c == 93 || c == 125 { if d == 0 { return j }; d -= 1 }
            if c == 44, d == 0 { return j }
            j += 1
        }
        return j
    }

    /// The UserDefaults keys in `lexed`: the `forKey:` argument of a read or write on `defaults`, `d` or
    /// `UserDefaults.standard`, and the keys of a `register(defaults: [...])` dictionary. A literal stays `"literal"`; a
    /// constant is resolved: `Self.x` → `<enclosing type>.x`, a local `let x = expr` → `expr`.
    static func defaultsKeys(_ lexed: Lexed, file: String) -> [String] {
        let code = lexed.code
        let text = String(decoding: code, as: UTF8.self)
        let declarations = declarations(in: code)
        var out: [String] = []
        let call = try! NSRegularExpression(pattern:
            #"\b(?:defaults|d|UserDefaults\.standard)\s*\.\s*(?:set|object|string|bool|double|integer|float|data|array|stringArray|dictionary|removeObject|url)\s*\("#)
        let bytes = { (r: NSRange) -> Int in text.utf8.distance(from: text.utf8.startIndex, to: Range(r, in: text)!.lowerBound) }
        for m in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let open = bytes(m.range) + text[Range(m.range, in: text)!].utf8.count
            let close = argumentListEnd(code, from: open)
            guard let label = find(code, ["forKey:"], from: open), label.upperBound <= close else { continue }
            let argStart = label.upperBound
            if let literal = lexed.literals.first(where: { $0.start >= argStart && $0.end <= close + 1 }),
               String(decoding: code[argStart..<literal.start], as: UTF8.self).trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("\"\(literal.body)\"")
                continue
            }
            var expression = String(decoding: code[argStart..<close], as: UTF8.self).filter { !$0.isWhitespace }
            if expression.hasPrefix("Self."), let owner = enclosingType(declarations, offset: argStart) {
                expression = owner + expression.dropFirst(4)
            } else if expression.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                      let local = localLet(expression, before: argStart, in: code) {
                expression = local
            }
            out.append(expression)
        }
        // register(defaults: ["Key": value, …])
        var from = 0
        while let r = find(code, ["register(defaults:"], from: from) {
            from = r.upperBound
            let close = argumentListEnd(code, from: r.lowerBound + "register(".utf8.count)
            for l in lexed.literals where l.start > r.upperBound && l.end <= close {
                let after = skipSpaces(code, l.end)
                if after < code.count, code[after] == 58 { out.append("\"\(l.body)\"") }   // a dictionary key
            }
        }
        return out
    }

    private static func argumentListEnd(_ code: [UInt8], from: Int) -> Int {
        var j = from, d = 0
        while j < code.count {
            if code[j] == 40 || code[j] == 91 { d += 1 }
            if code[j] == 41 || code[j] == 93 { if d == 0 { return j }; d -= 1 }
            j += 1
        }
        return j
    }

    private static func enclosingType(_ declarations: [Declaration], offset: Int) -> String? {
        declarations.filter { ($0.kind == .type || $0.kind == .extensionBody) && $0.body?.contains(offset) == true }
            .min { ($0.body?.count ?? 0) < ($1.body?.count ?? 0) }?.name
    }

    /// The expression of the nearest `let name = …` before `offset` (whitespace dropped), up to the end of its line.
    private static func localLet(_ name: String, before offset: Int, in code: [UInt8]) -> String? {
        let text = String(decoding: code[0..<offset], as: UTF8.self)
        guard let r = text.range(of: "let \(name) =", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        let line = rest.prefix { $0 != "\n" }
        let expression = line.filter { !$0.isWhitespace }
        return expression.isEmpty ? nil : expression
    }

    // MARK: - one pass over the popover

    struct Extracted: Equatable {
        var files: Set<String> = []
        var symbols: Set<String> = []
        /// name → the `file#symbol`s that use it (for the messages and for seeding a new row's entry).
        var strings: [String: Set<String>] = [:]
        var members: [String: Set<String>] = [:]
        var settings: [String: Set<String>] = [:]
        var sfSymbols: [String: Set<String>] = [:]
    }

    /// `popover`: the popover's files (relative path, text). `lSources`: every file that may declare L members.
    /// `stores`: the store files whose defaults keys count as settings.
    static func extract(popover: [(String, String)], lSources: [String], stores: [(String, String)]) -> Extracted {
        var x = Extracted()
        let known = lMembers(in: lSources)
        for (file, text) in popover {
            x.files.insert(file)
            let lexed = lex(text)
            let declarations = declarations(in: lexed.code)
            for d in declarations where d.kind != .extensionBody { x.symbols.insert("\(file)#\(d.name)") }
            func site(_ offset: Int) -> String { enclosing(declarations, offset: offset, file: file) }
            for (name, offset) in stringReferences(lexed.code, known: known) { x.strings[name, default: []].insert(site(offset)) }
            for (body, offset) in uiLiterals(lexed) { x.strings["\"\(body)\"", default: []].insert(site(offset)) }
            for (name, offset) in memberReferences(lexed.code) { x.members[name, default: []].insert(site(offset)) }
            for (name, offset) in sfSymbols(lexed) { x.sfSymbols[name, default: []].insert(site(offset)) }
        }
        for (file, text) in stores + popover.filter({ p in !stores.contains { $0.0 == p.0 } }) {
            for key in defaultsKeys(lex(text), file: file) { x.settings[key, default: []].insert(file) }
        }
        return x
    }
}
