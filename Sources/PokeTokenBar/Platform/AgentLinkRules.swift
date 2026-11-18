import Foundation

/// The `poketokenbar:` link on Windows (stage 7 Task 23, part b), as values: which start of the app carries a link, what that
/// start does, the most of a link it takes, and the one parse every link goes through, whether it came on the command line
/// (the shell starts `PokeTokenBar.exe --agent-link "<link>"`) or from that start over `WM_COPYDATA`. Both are untrusted (any
/// program or web page can open the link, any local program can send the message), so both end in the same place:
/// `AgentActivityEvent(url:)`, the Mac's own parser (scheme `poketokenbar`, host `agent`, a known `state`, `label` and `message`
/// cut to plain text). Nothing else is read from a link: no path, no file, no other command-line argument, and it never runs
/// anything. Shared so both systems test it.
enum AgentLinkRules {
    /// The longest link taken, in UTF-16 units (longer ones are dropped unread). The longest link the pet can show is under
    /// it: 320 scalars of message and 96 of label (`AgentActivityEvent`'s limits), percent-encoded at 12 characters a scalar
    /// at worst, is about 5,000 (5,042 with the rest of the link); the cap keeps a message from another program to a bounded copy.
    static let maxLength = 8_192

    /// `WM_COPYDATA`'s `dwData` for a link (ASCII "PTBA"); any other tag is refused.
    static let copyDataTag: UInt = 0x5054_4241

    /// The flag the installer's command puts before the link: `"…\PokeTokenBar.exe" --agent-link "%1"`. A link start is told by
    /// this flag, never by the link's own text.
    static let flag = "--agent-link"
    /// What a link start starts when no app runs: the app's quiet start (no popover; it yields quietly to an app that appears).
    static let cleanStartArguments = ["--autostart"]

    /// What a start of the app does with its command line (`arguments` with the program first).
    enum StartDecision: Equatable {
        /// Not a link start: the app starts with these arguments.
        case app([String])
        /// A link start while the app runs: the link goes to it and this start ends.
        case forward(String)
        /// A link start with no app running: a clean start of the app (`cleanStartArguments`, nothing of this command line),
        /// and the link is dropped, as on the Mac (Launch Services starts the app; the event comes before the pet exists).
        case startClean
        /// A link start that does nothing and ends: a command line of another shape (a link that broke out of its quotes and
        /// added arguments) or a link of another scheme.
        case drop
        /// A well-formed link start with no app running, from an elevated opener: nothing starts (the app would run elevated) and
        /// this start ends; Windows logs it, as it is the one well-formed link that starts nothing.
        case droppedElevated
    }

    /// The decision for a command line. A link start is `[exe, --agent-link, <link>]`, exactly: the shell's command quotes `%1`,
    /// so a link holding a quote that closes it adds arguments and is dropped whole. A first argument that is a link without
    /// the flag (another program's registration) is dropped too, never read as the app's flags.
    static func decide(_ arguments: [String], appRunning: () -> Bool, elevated: () -> Bool) -> StartDecision {
        guard arguments.count >= 2 else { return .app(arguments) }
        let first = arguments[1]
        if first != flag {
            return isLink(first) ? .drop : .app(arguments)
        }
        guard arguments.count == 3, isLink(arguments[2]) else { return .drop }
        if appRunning() { return .forward(arguments[2]) }
        return elevated() ? .droppedElevated : .startClean
    }

    /// Text that starts with `poketokenbar:` (any case).
    static func isLink(_ text: String) -> Bool { text.lowercased().hasPrefix(AgentActivityEvent.scheme + ":") }

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
