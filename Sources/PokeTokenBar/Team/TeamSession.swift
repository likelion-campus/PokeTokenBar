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
    /// No keyboard or mouse input for a while, with the plaza open or closed. Shown as zZ, in place.
    var isIdle = false
    /// The picked name colour as received; `PlazaNameColor` decides whether it can be shown.
    var nameColor: UInt32?
    /// Running on the current step, so their character here follows at running pace.
    var isRunning = false
    /// The latest plaza item slot they know was taken.
    var takenItemSlot: Int?
    /// When their focus ends, kept only if it passed `PlazaFocus.accepted` on receipt.
    var focusEndsAt: Date?
    /// Diving in the pond.
    var isDiving = false
    /// Their evolution stage, 1...3.
    var evolutionStage = 1
    /// The Ditto they host, kept only if it passed `PlazaDittoState.accepted` on receipt.
    var ditto: PlazaDittoState?
    /// Their plaza window is open and runs the Ditto.
    var dittoReady = false
}

/// Sits on a `TeamTransporting`: syncs news and reactions, keeps the member table, passes presence and
/// emotes. Saves no connection or presence history (the asleep list lives in memory only); emotes, chat and
/// profiles are never stored or forwarded.
@MainActor @Observable
final class TeamSession {
    static let heartbeatInterval: TimeInterval = 10
    static let silenceLimit: TimeInterval = 30
    static let inventoryInterval: TimeInterval = 300
    static let batchSize = 100
    /// More than a team has. A modified app can leave under new IDs for as long as it likes.
    static let maxAsleepMembers = 128
    /// One tiny frame asks for the whole feed back. An honest peer asks at connect and then every five minutes.
    nonisolated static let inventoryReplyBurst = 3
    nonisolated static let inventoryReplyInterval: TimeInterval = 30
    /// A profile is the whole dex, asked for when someone opens a card.
    nonisolated static let profileReplyBurst = 5
    nonisolated static let profileReplyInterval: TimeInterval = 2
    static let pruneInterval: TimeInterval = 3600
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
        var inventoryReplies = TeamTokenBucket(capacity: Double(TeamSession.inventoryReplyBurst),
                                               perSecond: 1 / TeamSession.inventoryReplyInterval)
        var profileReplies = TeamTokenBucket(capacity: Double(TeamSession.profileReplyBurst),
                                             perSecond: 1 / TeamSession.profileReplyInterval)
    }

    private struct PendingProfile {
        let memberID: String
        let continuation: CheckedContinuation<TeamMemberProfile?, Never>
        let timeout: Task<Void, Never>
    }

    /// Connected teammates, without me.
    private(set) var members: [String: TeamMemberState] = [:]
    /// Teammates seen since the team started whose connection is gone (Mac asleep, app quit), as last known.
    /// Memory only: cleared when the team stops or changes, and a teammate leaves it when they connect again.
    private(set) var asleepMembers: [String: TeamMemberState] = [:]
    /// No keyboard or mouse input on this Mac for a while (`TeamRuntime` decides). Sent with every presence.
    private(set) var isIdle = false
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
    @ObservationIgnored private var lastIncompatible: Date?
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// The code the app had last time `applySettings` looked; the baseline for "did the team change".
    @ObservationIgnored private var knownCode: TeamCode?
    @ObservationIgnored private var sentNickname: String?
    @ObservationIgnored private var sentNameColor: UInt32?
    @ObservationIgnored private var sentSchedule: PlazaSchedule?
    @ObservationIgnored private var character: TeamMonSummary?
    @ObservationIgnored private var inPlaza = false
    @ObservationIgnored private var tile: TilePoint?
    @ObservationIgnored private var facing: PlazaDirection?
    @ObservationIgnored private var isWalking = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var takenItemSlot: Int?
    @ObservationIgnored private var focusEndsAt: Date?
    @ObservationIgnored private var isDiving = false
    @ObservationIgnored private var dittoReady = false
    @ObservationIgnored private var dittoState: PlazaDittoState?
    @ObservationIgnored private let evolutionStage: () -> Int

    init(settings: TeamSettings, feed: TeamFeedStore, transport: TeamTransporting,
         profileProvider: @escaping () -> TeamMemberProfile,
         evolutionStage: @escaping () -> Int = { 1 }, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.feed = feed
        self.transport = transport
        self.profileProvider = profileProvider
        self.evolutionStage = evolutionStage
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
            if nickname != sentNickname || settings.nameColor != sentNameColor || settings.schedule != sentSchedule {
                sentNickname = nickname
                sentNameColor = settings.nameColor
                sentSchedule = settings.schedule
                broadcast(.presence(makePresence()))
            }
            return
        }
        if running { transport.stop() }
        resetConnections()
        pruneFeed()
        sentNickname = nickname
        sentNameColor = settings.nameColor
        sentSchedule = settings.schedule
        transport.start(code: code)
        running = true
    }

    func tick() {
        guard running else { return }
        let now = clock()
        if hasIncompatiblePeer, let seen = lastIncompatible, now.timeIntervalSince(seen) >= Self.incompatibleNoticeLifetime {
            hasIncompatiblePeer = false
        }
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

    func updatePlazaPosition(inPlaza: Bool, tile: TilePoint?, facing: PlazaDirection?, isWalking: Bool,
                             isRunning: Bool = false) {
        // 달리기는 칸을 출발할 때나 멈출 때만 바뀌므로 칸·걷기 변화 없이 혼자 바뀌지 않는다.
        let changed = inPlaza != self.inPlaza || tile != self.tile || facing != self.facing || isWalking != self.isWalking
        self.inPlaza = inPlaza
        self.tile = tile
        self.facing = facing
        self.isWalking = isWalking
        self.isRunning = isRunning
        if changed { broadcast(.presence(makePresence())) }
    }

    /// Tells teammates at once when I go idle or come back, whether or not the plaza is open.
    func updateIdle(_ idle: Bool) {
        guard idle != isIdle else { return }
        isIdle = idle
        broadcast(.presence(makePresence()))
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

    func sendEmote(_ kind: TeamEmoteKind, target: String?, shared: Bool = false, pushTiles: Int = 1, itemSlot: Int? = nil, fireworkStyle: String? = nil,
                   danceStyle: String? = nil, danceSince: Date? = nil, overDecoy: Bool = false,
                   snowballDirection: PlazaDirection? = nil) {
        broadcast(.emote(TeamEmote(kind: kind, targetMemberID: target, isShared: shared ? true : nil,
                                   pushTiles: pushTiles > 1 ? pushTiles : nil, itemSlot: itemSlot, fireworkStyle: fireworkStyle,
                                   danceStyle: danceStyle, danceSince: danceSince?.timeIntervalSince1970,
                                   overDecoy: overDecoy ? true : nil, snowballDirection: snowballDirection)))
    }

    /// The latest plaza item slot I know was taken, told to teammates in my presence (also to those who connect later).
    func updateTakenItemSlot(_ slot: Int?) {
        guard slot != takenItemSlot else { return }
        takenItemSlot = slot
        broadcast(.presence(makePresence()))
    }

    /// When my campfire focus ends (nil: not focusing), told to teammates in my presence.
    func updateFocus(endsAt: Date?) {
        guard endsAt != focusEndsAt else { return }
        focusEndsAt = endsAt
        broadcast(.presence(makePresence()))
    }

    /// Whether I am diving in the pond, told to teammates in my presence.
    func updateDiving(_ diving: Bool) {
        guard diving != isDiving else { return }
        isDiving = diving
        broadcast(.presence(makePresence()))
    }

    /// Whether my plaza runs the Ditto, and the Ditto I host (nil: not hosting), told to teammates in my presence.
    func updateDitto(ready: Bool, state: PlazaDittoState?) {
        guard ready != dittoReady || state != dittoState else { return }
        dittoReady = ready
        dittoState = state
        broadcast(.presence(makePresence()))
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
        asleepMembers[memberID] = members[memberID]
        if asleepMembers.count > Self.maxAsleepMembers, let other = asleepMembers.keys.first(where: { $0 != memberID }) {
            asleepMembers[other] = nil
        }
        members[memberID] = nil
        for (id, pending) in pendingProfiles where pending.memberID == memberID { finishProfileRequest(id, with: nil) }
    }

    private func resetConnections() {
        links = [:]
        members = [:]
        asleepMembers = [:]
        hasIncompatiblePeer = false
        lastIncompatible = nil
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
            member.character = presence.character.bounded
            member.inPlaza = presence.inPlaza
            member.tile = presence.tile
            member.facing = presence.facing
            member.isWalking = presence.isWalking
            member.isIdle = presence.isIdle ?? false
            member.nameColor = presence.nameColor
            member.isRunning = presence.isRunning ?? false
            member.takenItemSlot = presence.takenItemSlot
            member.focusEndsAt = PlazaFocus.accepted(presence.focusEndsAt, now: clock())
            member.isDiving = presence.isDiving ?? false
            member.evolutionStage = TeamEmote.pushTiles(presence.evolutionStage)
            member.ditto = PlazaDittoState.accepted(presence.ditto, now: clock())
            member.dittoReady = presence.dittoReady ?? false
            members[memberID] = member
            // 코드가 막 바뀌어 이전 팀 링크가 아직 살아 있는 동안에는 받은 일정을 새 팀 몫으로 저장하지 않는다.
            if let schedule = presence.schedule, settings.code == knownCode,
               settings.adoptSchedule(schedule, now: clock()) {
                sentSchedule = settings.schedule
                broadcast(.presence(makePresence()))
            }
        case .inventory(let eventIDs, let reactionIDs):
            guard links[peer]?.inventoryReplies.take(now: clock()) == true else { return }
            sendMissing(eventIDs: Set(eventIDs), reactionIDs: Set(reactionIDs), to: peer)
        case .events(let events, let live):
            // Nothing honest sends more, and a store pass over a frame this size stops the main thread for seconds.
            guard events.count <= Self.batchSize else { return }
            // A live frame is the sender's own news. Synced rows are other members' too, and nothing can check those.
            if live, events.contains(where: { $0.authorID != memberID }) { return }
            let added = feed.insert(events)
            // `publish` sends exactly one event per live frame, so a bigger "live" frame is not a moment
            // that just happened: store it, show nothing.
            if live, events.count == 1, let e = added.first, e.kind.isBig, e.occurredAt != nil { onBigEvent?(e) }
        case .reactions(let reactions, let live):
            guard reactions.count <= Self.batchSize else { return }
            if live, reactions.contains(where: { $0.authorID != memberID }) { return }
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
            guard links[peer]?.profileReplies.take(now: clock()) == true else { return }
            send(.profile(profileProvider()), to: peer)
        case .profile(let profile):
            for (id, pending) in pendingProfiles where pending.memberID == memberID {
                finishProfileRequest(id, with: profile)
            }
        }
    }

    private func receiveHello(_ hello: TeamHello, from peer: TeamPeerID) {
        guard links[peer]?.memberID == nil else { return }
        guard hello.memberID.utf8.count <= TeamWire.maxFieldBytes else {
            refuse(peer)
            return
        }
        // A refusal holds this link only. Anyone can say any member ID, so remembering the ID would lock the real member out.
        if hello.protocolVersion != TeamWire.protocolVersion {
            markIncompatible()
            refuse(peer)
            return
        }
        if hello.memberID == settings.memberID || hello.memberID == PlazaDitto.sceneKey {
            refuse(peer)
            return
        }
        let memberID = hello.memberID
        links[peer]?.memberID = memberID
        let character = hello.current.bounded
        var member = members[memberID] ?? TeamMemberState(memberID: memberID, nickname: "", character: character,
                                                          inPlaza: false, tile: nil, facing: nil, isWalking: false)
        if let nickname = TeamSettings.validNickname(hello.nickname) { member.nickname = nickname }
        member.character = character
        members[memberID] = member
        asleepMembers[memberID] = nil

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
        guard running, links[peer] != nil else { return }
        markIncompatible()
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
                     inPlaza: inPlaza, tile: tile, facing: facing, isWalking: isWalking, isIdle: isIdle ? true : nil,
                     nameColor: settings.nameColor, isRunning: isRunning ? true : nil, takenItemSlot: takenItemSlot,
                     focusEndsAt: focusEndsAt,
                     isDiving: isDiving ? true : nil, evolutionStage: { let n = evolutionStage(); return n > 1 ? n : nil }(),
                     schedule: settings.code == knownCode ? settings.schedule : nil,
                     ditto: dittoState, dittoReady: dittoReady ? true : nil)
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
