import Foundation

/// The order in which tray balloons are shown. Windows shows one balloon at a time (a second one replaces the first),
/// so a notification that arrives while one is up waits its turn. Pure: no OS calls, tested on both systems.
///
/// Rule: the first item shows at once; later ones wait in arrival order; at `capacity` waiting items the OLDEST
/// waiting one is dropped (the newest is the most relevant) and counted in `dropped`.
struct BalloonQueue {
    enum Kind: Equatable, CaseIterable { case app, team, hint }
    struct Item: Equatable {
        let id: String
        let title: String
        let body: String
        let sound: Bool
        let kind: Kind
    }

    /// `NOTIFYICONDATAW.szInfoTitle` (64) and `szInfo` (256) minus the terminating NUL, in UTF-16 units.
    static let titleLimit = 63, bodyLimit = 255

    private let capacity: Int
    private var pending: [Item] = []
    private(set) var inFlight: Item?
    private(set) var dropped = 0

    init(capacity: Int = 5) { self.capacity = max(1, capacity) }

    var pendingCount: Int { pending.count }

    /// The item to show now, or nil when it was queued behind the one on screen.
    mutating func offer(_ item: Item) -> Item? {
        if inFlight == nil {
            inFlight = item
            return item
        }
        if pending.count >= capacity {
            pending.removeFirst()
            dropped += 1
        }
        pending.append(item)
        return nil
    }

    /// After the shown balloon was clicked, hid or timed out: the next one to show, if any.
    mutating func finished() -> Item? {
        inFlight = pending.isEmpty ? nil : pending.removeFirst()
        return inFlight
    }

    /// At most `limit` UTF-16 units, cut on a character boundary (no split surrogate pair, no split Hangul syllable
    /// or combining sequence), ending in "…" when cut.
    static func clipped(_ s: String, limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var out = ""
        var units = 0
        for character in s {
            let n = character.utf16.count
            if units + n > limit - 1 { break }
            out.append(character)
            units += n
        }
        return out + "…"
    }
}

/// `NOTIFYICONDATAW.dwInfoFlags` for a tray balloon. Pure, so both systems pin the choice.
///
/// No kind sets `NIIF_RESPECT_QUIET_TIME` (0x80). Per Microsoft's documentation that flag suppresses the balloon during
/// "quiet time" (the first hour after a user signs in for the first time, and after an OS install or upgrade) and a
/// suppressed balloon is dropped, never kept in the notification centre. A fresh install on a new PC is exactly that
/// hour, so the first-run hint and every alert sent in it vanished. Focus assist / Do not disturb needs no flag: Windows
/// applies it to the toast it makes of every balloon (silently into the notification centre).
enum BalloonFlags {
    static let info: UInt32 = 0x1, noSound: UInt32 = 0x10, respectQuietTime: UInt32 = 0x80

    static func infoFlags(kind: BalloonQueue.Kind, sound: Bool) -> UInt32 {
        let quiet: UInt32
        switch kind {
        case .hint: quiet = 0   // the one chance to find the icon: must show even in the first hour
        case .app: quiet = 0    // limit alerts and companion events: a dropped one is lost for good
        case .team: quiet = 0   // team notices: same
        }
        return info | quiet | (sound ? 0 : noSound)
    }
}
