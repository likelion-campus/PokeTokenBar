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

    private struct StoredReaction: Codable {
        var reaction: TeamReaction
        var receivedAt: Date
    }

    private struct FileContents: Codable {
        var version = 1
        var events: [StoredEvent]
        var reactions: [StoredReaction]
        var lastReadAt: Date
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let myMemberID: String
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: Calendar

    private var stored: [StoredEvent] = []
    private var allReactions: [StoredReaction] = []
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
        allReactions.map(\.reaction).filter { $0.eventID == eventID }.sorted(by: Self.reactionOrder)
    }

    var eventIDs: Set<String> { Set(stored.map(\.event.id)) }
    var reactionIDs: Set<String> { Set(allReactions.map(\.reaction.id)) }

    func events(notIn ids: Set<String>) -> [TeamEvent] {
        stored.map(\.event).filter { !ids.contains($0.id) }
    }

    func reactions(notIn ids: Set<String>) -> [TeamReaction] {
        allReactions.map(\.reaction).filter { !ids.contains($0.id) }.sorted(by: Self.reactionOrder)
    }

    var unreadCount: Int {
        let unreadEvents = stored.filter { $0.event.authorID != myMemberID && $0.receivedAt > lastReadAt }.count
        let myEventIDs = Set(stored.filter { $0.event.authorID == myMemberID }.map(\.event.id))
        let unreadReactions = allReactions.filter {
            $0.reaction.authorID != myMemberID && myEventIDs.contains($0.reaction.eventID) && $0.receivedAt > lastReadAt
        }.count
        return unreadEvents + unreadReactions
    }

    // MARK: - Mutations

    @discardableResult
    func insert(_ e: TeamEvent) -> Bool {
        guard !stored.contains(where: { $0.event.id == e.id }) else { return false }
        stored.append(StoredEvent(event: e, receivedAt: clock()))
        sortEvents()
        prune()
        save()
        // An event pruned right away (too old / beyond the cap) is not "new".
        return stored.contains(where: { $0.event.id == e.id })
    }

    @discardableResult
    func insert(_ r: TeamReaction) -> Bool {
        guard !allReactions.contains(where: { $0.reaction.id == r.id }) else { return false }
        var r = r
        if r.kind == .comment {
            let trimmed = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...TeamReaction.maxCommentLength).contains(trimmed.count) else { return false }
            r = TeamReaction(id: r.id, eventID: r.eventID, authorID: r.authorID, authorNickname: r.authorNickname,
                             kind: r.kind, text: trimmed, createdAt: r.createdAt)
        } else if allReactions.contains(where: {
            $0.reaction.authorID == r.authorID && $0.reaction.eventID == r.eventID && $0.reaction.kind == r.kind
        }) {
            return false
        }
        allReactions.append(StoredReaction(reaction: r, receivedAt: clock()))
        save()
        return true
    }

    func markAllRead() {
        lastReadAt = clock()
        save()
    }

    /// Wipes events, reactions and the read marker (used when moving to another team).
    func reset() {
        stored = []
        allReactions = []
        lastReadAt = .distantPast
        save()
    }

    /// Saves only when something was dropped, so a fresh store never creates its file.
    func prune() {
        let before = (stored.count, allReactions.count)
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
        allReactions.removeAll { !present.contains($0.reaction.eventID) && $0.reaction.createdAt < cutoff }
        if (stored.count, allReactions.count) != before { save() }
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
