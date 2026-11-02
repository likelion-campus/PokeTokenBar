import Foundation
import Observation

/// Local, persisted team feed: events, reactions and a read marker.
/// Lives in its own file so the save (`companion-state.json`) is never touched.
@MainActor @Observable
final class TeamFeedStore {
    static let retentionDays = 7
    static let maxEvents = 300
    static let maxReactions = 3000

    /// `seq` is a local arrival counter: it orders unread without recording when anything arrived.
    private struct StoredEvent: Codable {
        var event: TeamEvent
        var seq: Int
    }

    private struct StoredReaction: Codable {
        var reaction: TeamReaction
        var seq: Int
    }

    private struct FileContents: Codable {
        var version = 1
        var events: [StoredEvent]
        var reactions: [StoredReaction]
        var lastReadSeq: Int
        var nextSeq: Int
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let myMemberID: String
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: Calendar

    private var stored: [StoredEvent] = []
    private var allReactions: [StoredReaction] = []
    private var lastReadSeq = 0
    private var nextSeq = 1

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
        let unreadEvents = stored.filter { $0.event.authorID != myMemberID && $0.seq > lastReadSeq }.count
        let myEventIDs = Set(stored.filter { $0.event.authorID == myMemberID }.map(\.event.id))
        let unreadReactions = allReactions.filter {
            $0.reaction.authorID != myMemberID && myEventIDs.contains($0.reaction.eventID) && $0.seq > lastReadSeq
        }.count
        return unreadEvents + unreadReactions
    }

    // MARK: - Mutations

    /// Counts whole-file writes, so tests can pin one save per frame.
    @ObservationIgnored private(set) var saveCount = 0

    @discardableResult
    func insert(_ e: TeamEvent) -> Bool { !insert([e]).isEmpty }

    @discardableResult
    func insert(_ r: TeamReaction) -> Bool { !insert([r]).isEmpty }

    /// Admits a whole frame with one prune and one save. Returns the events that are new and still kept.
    func insert(_ events: [TeamEvent]) -> [TeamEvent] {
        var added: [TeamEvent] = []
        for e in events where admits(e) && !stored.contains(where: { $0.event.id == e.id }) {
            stored.append(StoredEvent(event: e, seq: takeSeq()))
            added.append(e)
        }
        guard !added.isEmpty else { return [] }
        sortEvents()
        prune()
        save()
        // An event pruned right away (beyond the cap) is not "new".
        let kept = Set(stored.map(\.event.id))
        return added.filter { kept.contains($0.id) }
    }

    func insert(_ reactions: [TeamReaction]) -> [TeamReaction] {
        var added: [TeamReaction] = []
        for r in reactions where admits(r) && !allReactions.contains(where: { $0.reaction.id == r.id }) {
            guard !allReactions.contains(where: {
                $0.reaction.authorID == r.authorID && $0.reaction.eventID == r.eventID && $0.reaction.kind == r.kind
            }) else { continue }
            allReactions.append(StoredReaction(reaction: dayOnly(r), seq: takeSeq()))
            added.append(r)
        }
        guard !added.isEmpty else { return [] }
        if allReactions.count > Self.maxReactions {
            allReactions.sort { Self.reactionOrder($0.reaction, $1.reaction) }
            allReactions.removeFirst(allReactions.count - Self.maxReactions)
        }
        save()
        let kept = Set(allReactions.map(\.reaction.id))
        return added.filter { kept.contains($0.id) }
    }

    func markAllRead() {
        lastReadSeq = nextSeq - 1
        save()
    }

    /// Wipes events, reactions and the read marker (used when moving to another team).
    func reset() {
        stored = []
        allReactions = []
        lastReadSeq = 0
        nextSeq = 1
        try? FileManager.default.removeItem(atPath: fileURL.path + ".corrupt")
        save()
    }

    /// Saves only when something was dropped, so a fresh store never creates its file.
    func prune() {
        let before = (stored.count, allReactions.count)
        let cutoff = retentionCutoff()
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

    private func takeSeq() -> Int {
        defer { nextSeq += 1 }
        return nextSeq
    }

    /// R26: a reaction keeps the day it was made, never the time of day (a sender may not have rounded).
    private func dayOnly(_ r: TeamReaction) -> TeamReaction {
        TeamReaction(id: r.id, eventID: r.eventID, authorID: r.authorID, authorNickname: r.authorNickname,
                     kind: r.kind, text: nil, createdAt: calendar.startOfDay(for: r.createdAt))
    }

    // MARK: - Admission

    private static let maxFieldBytes = 64

    private func bounded(_ strings: String?...) -> Bool {
        strings.allSatisfy { ($0?.utf8.count ?? 0) <= Self.maxFieldBytes }
    }

    /// Dates must lie between the retention cutoff and tomorrow, so no row is born expired, never expires,
    /// or carries a date the file cannot be decoded with.
    private func inWindow(_ date: Date, extraDaysBelow: Int = 0) -> Bool {
        let now = clock()
        let lower = calendar.date(byAdding: .day, value: -extraDaysBelow, to: retentionCutoff()) ?? retentionCutoff()
        return date >= lower && date <= now.addingTimeInterval(86_400)
    }

    private func retentionCutoff() -> Date {
        let today = calendar.startOfDay(for: clock())
        return calendar.date(byAdding: .day, value: -Self.retentionDays, to: today) ?? today
    }

    private func admits(_ e: TeamEvent) -> Bool {
        guard !e.id.isEmpty, !e.authorID.isEmpty, bounded(e.id, e.authorID, e.speciesName, e.fromSpeciesName),
              TeamSettings.validNickname(e.authorNickname) != nil,
              let day = dayStart(e.day), inWindow(day) else { return false }
        // The `day` string decides the lower bound; the instant gets one more day below the cutoff because
        // the sender's calendar may be a day ahead of this one.
        if let at = e.occurredAt, !inWindow(at, extraDaysBelow: 1) { return false }
        return true
    }

    /// R25: comments are not part of the feature, so they are never stored (the enum case stays for the wire).
    private func admits(_ r: TeamReaction) -> Bool {
        guard r.kind != .comment, !r.id.isEmpty, !r.eventID.isEmpty, !r.authorID.isEmpty,
              bounded(r.id, r.eventID, r.authorID), TeamSettings.validNickname(r.authorNickname) != nil,
              inWindow(r.createdAt) else { return false }
        return true
    }

    // MARK: - Helpers

    private static func reactionOrder(_ a: TeamReaction, _ b: TeamReaction) -> Bool {
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }

    /// `day` is always Gregorian (`TeamEventFactory`), whatever calendar this Mac is set to.
    private func dayStart(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
            lastReadSeq = contents.lastReadSeq
            nextSeq = contents.nextSeq
            sortEvents()
        } catch {
            let backup = URL(fileURLWithPath: fileURL.path + ".corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            stored = []
            allReactions = []
            lastReadSeq = 0
            nextSeq = 1
        }
    }

    private func save() {
        saveCount += 1
        let contents = FileContents(events: stored, reactions: allReactions, lastReadSeq: lastReadSeq, nextSeq: nextSeq)
        guard let data = try? Self.makeEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
