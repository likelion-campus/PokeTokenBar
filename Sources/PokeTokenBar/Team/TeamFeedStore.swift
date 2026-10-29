import Foundation
import Observation

/// Local, persisted team feed: events, reactions and a read marker.
/// Lives in its own file so the save (`companion-state.json`) is never touched.
@MainActor @Observable
final class TeamFeedStore {
    static let retentionDays = 7
    static let maxEvents = 300

    private struct StoredEvent: Codable {
        var event: TeamEvent
        var receivedAt: Date
    }

    private struct FileContents: Codable {
        var version = 1
        var events: [StoredEvent]
        var reactions: [TeamReaction]
        var lastReadAt: Date
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let myMemberID: String
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: Calendar

    private var stored: [StoredEvent] = []
    private var allReactions: [TeamReaction] = []
    private var lastReadAt: Date = .distantPast

    /// Newest first, keyed by `occurredAt ?? startOfDay(day)`.
    var events: [TeamEvent] { stored.map(\.event) }

    init(fileURL: URL = AppStatePaths.directory().appendingPathComponent("team-feed.json"),
         myMemberID: String,
         clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.myMemberID = myMemberID
        self.clock = clock
        self.calendar = calendar
        load()
        prune()
    }

    // MARK: - Queries

    func reactions(for eventID: String) -> [TeamReaction] {
        allReactions.filter { $0.eventID == eventID }.sorted(by: Self.reactionOrder)
    }

    var eventIDs: Set<String> { Set(stored.map(\.event.id)) }
    var reactionIDs: Set<String> { Set(allReactions.map(\.id)) }

    func events(notIn ids: Set<String>) -> [TeamEvent] {
        stored.map(\.event).filter { !ids.contains($0.id) }
    }

    func reactions(notIn ids: Set<String>) -> [TeamReaction] {
        allReactions.filter { !ids.contains($0.id) }.sorted(by: Self.reactionOrder)
    }

    var unreadCount: Int {
        stored.filter { $0.event.authorID != myMemberID && $0.receivedAt > lastReadAt }.count
    }

    // MARK: - Mutations

    @discardableResult
    func insert(_ e: TeamEvent) -> Bool {
        guard !stored.contains(where: { $0.event.id == e.id }) else { return false }
        stored.append(StoredEvent(event: e, receivedAt: clock()))
        sortEvents()
        prune()   // saves
        return true
    }

    @discardableResult
    func insert(_ r: TeamReaction) -> Bool {
        guard !allReactions.contains(where: { $0.id == r.id }) else { return false }
        var r = r
        if r.kind == .comment {
            let trimmed = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...TeamReaction.maxCommentLength).contains(trimmed.count) else { return false }
            r = TeamReaction(id: r.id, eventID: r.eventID, authorID: r.authorID, authorNickname: r.authorNickname,
                             kind: r.kind, text: trimmed, createdAt: r.createdAt)
        } else if allReactions.contains(where: {
            $0.authorID == r.authorID && $0.eventID == r.eventID && $0.kind == r.kind
        }) {
            return false
        }
        allReactions.append(r)
        save()
        return true
    }

    func markAllRead() {
        lastReadAt = clock()
        save()
    }

    func prune() {
        let today = calendar.startOfDay(for: clock())
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: today) ?? today
        // Events whose day cannot be parsed are kept until the cap trims them.
        stored.removeAll { s in
            guard let d = dayStart(s.event.day) else { return false }
            return d < cutoff
        }
        sortEvents()
        if stored.count > Self.maxEvents { stored.removeLast(stored.count - Self.maxEvents) }
        let present = Set(stored.map(\.event.id))
        // A reaction can arrive before its event during sync: only drop stale orphans.
        allReactions.removeAll { !present.contains($0.eventID) && $0.createdAt < cutoff }
        save()
    }

    // MARK: - Helpers

    private static func reactionOrder(_ a: TeamReaction, _ b: TeamReaction) -> Bool {
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }

    private func dayStart(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func sortKey(_ e: TeamEvent) -> Date {
        e.occurredAt ?? dayStart(e.day) ?? .distantPast
    }

    private func sortEvents() {
        stored.sort {
            let a = sortKey($0.event), b = sortKey($1.event)
            return a == b ? $0.event.id < $1.event.id : a > b
        }
    }

    // MARK: - Persistence

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try Self.makeDecoder().decode(FileContents.self, from: data)
            stored = contents.events
            allReactions = contents.reactions
            lastReadAt = contents.lastReadAt
            sortEvents()
        } catch {
            let backup = URL(fileURLWithPath: fileURL.path + ".corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            stored = []
            allReactions = []
            lastReadAt = .distantPast
        }
    }

    private func save() {
        let contents = FileContents(events: stored, reactions: allReactions, lastReadAt: lastReadAt)
        guard let data = try? Self.makeEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
