import Foundation

/// The `poketokenbar:` link on Windows (stage 7 Task 23, part b), as values: which start of the app carries a link, the most
/// of one it takes, and the one parse every link goes through, whether it came on the command line (the shell starts
/// `PokeTokenBar.exe "<link>"`) or from a second start over `WM_COPYDATA`. Both are untrusted (any program or web page can
/// open the link, any local program can send the message), so both end in the same place: `AgentActivityEvent(url:)`, the
/// Mac's own parser (scheme `poketokenbar`, host `agent`, a known `state`, `label` and `message` cut to plain text).
/// Nothing else is read from a link: no path, no file, no other command-line argument, and it never runs anything.
/// Shared so both systems test it.
enum AgentLinkRules {
    /// The longest link taken, in UTF-16 units (longer ones are dropped unread). The longest link the pet can show is well
    /// under it: an 80-character message and a 24-character label, percent-encoded at 12 bytes a character at worst, is
    /// about 1,300; the cap keeps a message from another program to a bounded copy.
    static let maxLength = 8_192

    /// `WM_COPYDATA`'s `dwData` for a link (ASCII "PTBA"); any other tag is refused.
    static let copyDataTag: UInt = 0x5054_4241

    /// A start carrying a link: its first argument begins with `poketokenbar:` (any case). The shell's command is
    /// `"…\PokeTokenBar.exe" "%1"`, so a link is always the first argument; a link that closes its quote and adds more
    /// arguments (`…" --flag`) still starts with the scheme, and everything after it is ignored.
    static func link(in arguments: [String]) -> String? {
        guard arguments.count >= 2 else { return nil }
        let first = arguments[1]
        return first.lowercased().hasPrefix(AgentActivityEvent.scheme + ":") ? first : nil
    }

    /// The event a link carries, or nil: too long, not a URL, or not one the Mac's parser takes.
    static func event(fromLink link: String) -> AgentActivityEvent? {
        guard link.utf16.count <= maxLength, let url = URL(string: link) else { return nil }
        return AgentActivityEvent(url: url)
    }

    /// The link as `WM_COPYDATA` carries it: UTF-16 code units, no terminator.
    static func payload(_ link: String) -> [UInt16]? {
        let units = Array(link.utf16)
        return units.isEmpty || units.count > maxLength ? nil : units
    }

    /// A `WM_COPYDATA` payload back to a link: the right tag, a whole number of UTF-16 units, at most `maxLength` of them,
    /// none of them NUL, valid UTF-16. Nil for anything else.
    static func link(tag: UInt, bytes: UnsafeRawBufferPointer) -> String? {
        guard tag == copyDataTag, !bytes.isEmpty, bytes.count % 2 == 0, bytes.count / 2 <= maxLength else { return nil }
        var units = [UInt16](repeating: 0, count: bytes.count / 2)
        units.withUnsafeMutableBytes { $0.copyMemory(from: bytes) }
        guard !units.contains(0) else { return nil }
        var text = ""
        var decoder = UTF16()
        var iterator = units.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let s): text.unicodeScalars.append(s)
            case .emptyInput: return text
            case .error: return nil
            }
        }
    }
}
