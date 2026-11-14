import Foundation

/// The order in which tray balloons are shown. Windows shows one balloon at a time (a second one replaces the first),
/// so a notification that arrives while one is up waits its turn. Pure: no OS calls, tested on both systems.
///
/// Rule: the first item shows at once; later ones wait in arrival order; at `capacity` waiting items the OLDEST
/// waiting one is dropped (the newest is the most relevant) and counted in `dropped`.
struct BalloonQueue {
    enum Kind: Equatable { case app, team }
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
