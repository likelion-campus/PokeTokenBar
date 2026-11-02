import Foundation
import Observation

/// What this Mac knows about one connected teammate. Never persisted.
struct TeamMemberState: Equatable, Sendable {
    var memberID: String
    var nickname: String
    var character: TeamMonSummary
    var inPlaza: Bool
    var tile: TilePoint?
    var facing: PlazaDirection?
    var isWalking: Bool
    /// In the plaza but not at the keyboard. Shown as zZ in place, not moved to the shelter.
    var isIdle = false
}

/// Sits on a `TeamTransporting`: syncs news and reactions, keeps the member table, passes presence and
/// emotes. Keeps no connection or presence history; emotes, chat and profiles are never stored or forwarded.
@MainActor @Observable
final class TeamSession {
    static let heartbeatInterval: TimeInterval = 10
    static let silenceLimit: TimeInterval = 30
    static let inventoryInterval: TimeInterval = 300
    static let batchSize = 100
    static let pruneInterval: TimeInterval = 3600
    /// A member the session refused (other version, same member ID, undecodable frame) is not served again for this long.
    static let refusalCooldown: TimeInterval = 300
    /// `hasIncompatiblePeer` clears when no mismatch was seen for this long.
    static let incompatibleNoticeLifetime: TimeInterval = 600

    private struct Link {
        let initiatedByMe: Bool
        /// Higher is newer.
        let sequence: Int
        /// Nil until the peer's `hello` arrives.
        var memberID: String?
        var lastReceived: Date
        var lastSent: Date
        var lastInventory: Date
    }

    private struct PendingProfile {
        let memberID: String
        let continuation: CheckedContinuation<TeamMemberProfile?, Never>
        let timeout: Task<Void, Never>
    }

    /// Connected teammates, without me.
    private(set) var members: [String: TeamMemberState] = [:]
    private(set) var hasIncompatiblePeer = false
    var hasOnlinePeers: Bool { !members.isEmpty }

    @ObservationIgnored var onBigEvent: ((TeamEvent) -> Void)?
    @ObservationIgnored var onReactionToMine: ((TeamReaction, TeamEvent) -> Void)?
    @ObservationIgnored var onEmote: ((_ memberID: String, TeamEmote) -> Void)?
    @ObservationIgnored var onChat: ((_ memberID: String, _ text: String, _ isLoud: Bool) -> Void)?

    @ObservationIgnored private let settings: TeamSettings
    @ObservationIgnored private let feed: TeamFeedStore
    @ObservationIgnored private let transport: TeamTransporting
    @ObservationIgnored private let profileProvider: () -> TeamMemberProfile
    @ObservationIgnored private let clock: () -> Date

    @ObservationIgnored private var links: [TeamPeerID: Link] = [:]
    @ObservationIgnored private var linkCounter = 0
    @ObservationIgnored private var pendingProfiles: [UUID: PendingProfile] = [:]
    @ObservationIgnored private var running = false
    @ObservationIgnored private var refusedUntil: [String: Date] = [:]
    @ObservationIgnored private var lastIncompatible: Date?
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// The code the app had last time `applySettings` looked; the baseline for "did the team change".
    @ObservationIgnored private var knownCode: TeamCode?
    @ObservationIgnored private var sentNickname: String?
    @ObservationIgnored private var character: TeamMonSummary?
    @ObservationIgnored private var inPlaza = false
    @ObservationIgnored private var isIdle = false
    @ObservationIgnored private var tile: TilePoint?
    @ObservationIgnored private var facing: PlazaDirection?
    @ObservationIgnored private var isWalking = false

    init(settings: TeamSettings, feed: TeamFeedStore, transport: TeamTransporting,
         profileProvider: @escaping () -> TeamMemberProfile, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.feed = feed
        self.transport = transport
        self.profileProvider = profileProvider
        self.clock = clock
        knownCode = settings.code
        transport.onPeerConnected = { [weak self] peer, initiatedByMe in
            self?.peerConnected(peer, initiatedByMe: initiatedByMe)
        }
        transport.onPeerDisconnected = { [weak self] peer in self?.dropLink(peer) }
        transport.onMessage = { [weak self] peer, message in self?.receive(message, from: peer) }
        transport.onPeerBadFrame = { [weak self] peer in self?.receiveBadFrame(from: peer) }
    }

    // MARK: - Settings

    func applySettings() {
        let code = settings.code
        let codeChanged = code != knownCode
        if codeChanged {
            if knownCode != nil { feed.reset() }
            knownCode = code
        }
        guard settings.isReady, let code, let nickname = TeamSettings.validNickname(settings.nickname) else {
            if running {
                transport.stop()
                running = false
                resetConnections()
            }
            return
        }
        if running && !codeChanged {
            if nickname != sentNickname {
                sentNickname = nickname
                broadcast(.presence(makePresence()))
            }
            return
        }
        if running { transport.stop() }
        resetConnections()
        pruneFeed()
        sentNickname = nickname
        transport.start(code: code)
        running = true
    }

    func tick() {
        guard running else { return }
        let now = clock()
        if hasIncompatiblePeer, let seen = lastIncompatible, now.timeIntervalSince(seen) >= Self.incompatibleNoticeLifetime {
            hasIncompatiblePeer = false
        }
        refusedUntil = refusedUntil.filter { $0.value > now }
        if now.timeIntervalSince(lastPrune) >= Self.pruneInterval { pruneFeed() }
        for (peer, link) in links where now.timeIntervalSince(link.lastReceived) >= Self.silenceLimit {
            transport.disconnect(peer, coveredBy: nil)
            dropLink(peer)
        }
        for (peer, link) in links where link.memberID != nil {
            if now.timeIntervalSince(link.lastSent) >= Self.heartbeatInterval { send(.presence(makePresence()), to: peer) }
            if now.timeIntervalSince(link.lastInventory) >= Self.inventoryInterval { sendInventory(to: peer) }
        }
    }

    private func pruneFeed() {
        feed.prune()
        lastPrune = clock()
    }

    // MARK: - My state

    func updateCharacter(_ c: TeamMonSummary) {
        let changed = c != currentCharacter
        character = c
        if changed { broadcast(.presence(makePresence())) }
    }

    func updatePlazaPosition(inPlaza: Bool, tile: TilePoint?, facing: PlazaDirection?, isWalking: Bool, isIdle: Bool = false) {
        let changed = inPlaza != self.inPlaza || tile != self.tile || facing != self.facing || isWalking != self.isWalking
            || isIdle != self.isIdle
        self.isIdle = isIdle
        self.inPlaza = inPlaza
        self.tile = tile
        self.facing = facing
        self.isWalking = isWalking
        if changed { broadcast(.presence(makePresence())) }
    }

    // MARK: - News, reactions, emotes

    func publish(_ e: CompanionTeamEvent) {
        guard settings.isReady, let nickname = TeamSettings.validNickname(settings.nickname) else { return }
        let event = TeamEventFactory.make(e, authorID: settings.memberID, nickname: nickname, now: clock(),
                                          hasOnlinePeers: hasOnlinePeers)
        guard feed.insert(event) else { return }
        broadcast(.events([event], live: true))
        if event.kind.isBig, event.occurredAt != nil { onBigEvent?(event) }
    }

    func react(to eventID: String, kind: TeamReactionKind) {
        guard settings.isReady, let nickname = TeamSettings.validNickname(settings.nickname) else { return }
        let reaction = TeamReaction(id: UUID().uuidString, eventID: eventID, authorID: settings.memberID,
                                    authorNickname: nickname, kind: kind, text: nil,
                                    createdAt: Calendar.current.startOfDay(for: clock()))
        guard feed.insert(reaction) else { return }
        broadcast(.reactions([reaction], live: true))
    }

    func sendEmote(_ kind: TeamEmoteKind, target: String?) {
        broadcast(.emote(TeamEmote(kind: kind, targetMemberID: target)))
    }

    func sendChat(_ text: String, loud: Bool = false) {
        broadcast(.chat(TeamChat(text: text, isLoud: loud ? true : nil)))
    }

    func requestProfile(memberID: String, timeout: Duration = .seconds(5)) async -> TeamMemberProfile? {
        guard let peer = links.first(where: { $0.value.memberID == memberID })?.key else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let task = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishProfileRequest(id, with: nil)
            }
            pendingProfiles[id] = PendingProfile(memberID: memberID, continuation: continuation, timeout: task)
            send(.profileRequest, to: peer)
        }
    }

    // MARK: - Connections

    private func peerConnected(_ peer: TeamPeerID, initiatedByMe: Bool) {
        guard running else { return }
        linkCounter += 1
        let now = clock()
        links[peer] = Link(initiatedByMe: initiatedByMe, sequence: linkCounter, memberID: nil,
                           lastReceived: now, lastSent: now, lastInventory: now)
        let hello = TeamHello(memberID: settings.memberID, nickname: TeamSettings.validNickname(settings.nickname) ?? "",
                              protocolVersion: TeamWire.protocolVersion, current: currentCharacter)
        send(.hello(hello), to: peer)
    }

    /// Idempotent. The member leaves the table once its last connection is gone.
    private func dropLink(_ peer: TeamPeerID) {
        guard let link = links.removeValue(forKey: peer), let memberID = link.memberID else { return }
        guard !links.values.contains(where: { $0.memberID == memberID }) else { return }
        members[memberID] = nil
        for (id, pending) in pendingProfiles where pending.memberID == memberID { finishProfileRequest(id, with: nil) }
    }

    private func resetConnections() {
        links = [:]
        members = [:]
        hasIncompatiblePeer = false
        lastIncompatible = nil
        refusedUntil = [:]
        for id in Array(pendingProfiles.keys) { finishProfileRequest(id, with: nil) }
    }

    private func finishProfileRequest(_ id: UUID, with profile: TeamMemberProfile?) {
        guard let pending = pendingProfiles.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(returning: profile)
    }

    // MARK: - Receiving

    private func receive(_ message: TeamMessage, from peer: TeamPeerID) {
        guard running, links[peer] != nil else { return }
        links[peer]?.lastReceived = clock()
        if case .hello(let hello) = message {
            receiveHello(hello, from: peer)
            return
        }
        guard let memberID = links[peer]?.memberID else { return }
        switch message {
        case .hello:
            break
        case .presence(let presence):
            guard var member = members[memberID] else { return }
            if let nickname = TeamSettings.validNickname(presence.nickname) { member.nickname = nickname }
            member.character = presence.character
            member.inPlaza = presence.inPlaza
            member.tile = presence.tile
            member.facing = presence.facing
            member.isWalking = presence.isWalking
            member.isIdle = presence.isIdle ?? false
            members[memberID] = member
        case .inventory(let eventIDs, let reactionIDs):
            sendMissing(eventIDs: Set(eventIDs), reactionIDs: Set(reactionIDs), to: peer)
        case .events(let events, let live):
            let added = feed.insert(events)
            // `publish` sends exactly one event per live frame, so a bigger "live" frame is not a moment
            // that just happened: store it, show nothing.
            if live, events.count == 1, let e = added.first, e.kind.isBig, e.occurredAt != nil { onBigEvent?(e) }
        case .reactions(let reactions, let live):
            for r in feed.insert(reactions) {
                guard live, let event = feed.events.first(where: { $0.id == r.eventID }),
                      event.authorID == settings.memberID else { continue }
                onReactionToMine?(r, event)
            }
        case .emote(let emote):
            onEmote?(memberID, emote)
        case .chat(let chat):
            if TeamChat.prepared(chat.text) == chat.text { onChat?(memberID, chat.text, chat.isLoud ?? false) }
        case .profileRequest:
            send(.profile(profileProvider()), to: peer)
        case .profile(let profile):
            for (id, pending) in pendingProfiles where pending.memberID == memberID {
                finishProfileRequest(id, with: profile)
            }
        }
    }

    private func receiveHello(_ hello: TeamHello, from peer: TeamPeerID) {
        guard links[peer]?.memberID == nil else { return }
        let now = clock()
        if let until = refusedUntil[hello.memberID], now < until {
            refuse(peer)
            return
        }
        if hello.protocolVersion != TeamWire.protocolVersion {
            markIncompatible()
            refusedUntil[hello.memberID] = now.addingTimeInterval(Self.refusalCooldown)
            refuse(peer)
            return
        }
        if hello.memberID == settings.memberID {
            refuse(peer)
            return
        }
        let memberID = hello.memberID
        links[peer]?.memberID = memberID
        var member = members[memberID] ?? TeamMemberState(memberID: memberID, nickname: "", character: hello.current,
                                                          inPlaza: false, tile: nil, facing: nil, isWalking: false)
        if let nickname = TeamSettings.validNickname(hello.nickname) { member.nickname = nickname }
        member.character = hello.current
        members[memberID] = member

        // Both sides run the same rule, so they keep the same connection.
        let mine = settings.memberID
        let preferredInitiator = min(mine, memberID)
        let candidates = links.filter { $0.value.memberID == memberID }.sorted { $0.value.sequence > $1.value.sequence }
        let kept = candidates.first { ($0.value.initiatedByMe ? mine : memberID) == preferredInitiator } ?? candidates[0]
        for (other, _) in candidates where other != kept.key {
            transport.disconnect(other, coveredBy: kept.key)
            dropLink(other)
        }
        sendInventory(to: kept.key)
        send(.presence(makePresence()), to: kept.key)
    }

    /// A frame this version cannot read: the same as a mismatch, because resending it would only repeat it.
    private func receiveBadFrame(from peer: TeamPeerID) {
        guard running, let link = links[peer] else { return }
        markIncompatible()
        if let memberID = link.memberID { refusedUntil[memberID] = clock().addingTimeInterval(Self.refusalCooldown) }
        refuse(peer)
    }

    private func markIncompatible() {
        hasIncompatiblePeer = true
        lastIncompatible = clock()
    }

    /// Owner-initiated disconnects are silent, so the link leaves the table right here.
    private func refuse(_ peer: TeamPeerID) {
        transport.refuse(peer)
        dropLink(peer)
    }

    // MARK: - Sending

    private var currentCharacter: TeamMonSummary { character ?? profileProvider().current }

    private func makePresence() -> TeamPresence {
        TeamPresence(nickname: TeamSettings.validNickname(settings.nickname) ?? "", character: currentCharacter,
                     inPlaza: inPlaza, tile: tile, facing: facing, isWalking: isWalking, isIdle: isIdle ? true : nil)
    }

    private func send(_ message: TeamMessage, to peer: TeamPeerID) {
        guard links[peer] != nil else { return }
        links[peer]?.lastSent = clock()
        transport.send(message, to: peer)
    }

    private func broadcast(_ message: TeamMessage) {
        guard running else { return }
        for (peer, link) in links where link.memberID != nil { send(message, to: peer) }
    }

    private func sendInventory(to peer: TeamPeerID) {
        links[peer]?.lastInventory = clock()
        send(.inventory(eventIDs: Array(feed.eventIDs), reactionIDs: Array(feed.reactionIDs)), to: peer)
    }

    private func sendMissing(eventIDs: Set<String>, reactionIDs: Set<String>, to peer: TeamPeerID) {
        let events = feed.events(notIn: eventIDs)
        for start in stride(from: 0, to: events.count, by: Self.batchSize) {
            send(.events(Array(events[start..<min(start + Self.batchSize, events.count)]), live: false), to: peer)
        }
        let reactions = feed.reactions(notIn: reactionIDs)
        for start in stride(from: 0, to: reactions.count, by: Self.batchSize) {
            send(.reactions(Array(reactions[start..<min(start + Self.batchSize, reactions.count)]), live: false), to: peer)
        }
    }
}
