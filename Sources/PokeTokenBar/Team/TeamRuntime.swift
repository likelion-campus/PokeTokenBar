import Foundation
import CoreGraphics

/// Ties the companion and the team settings to the `TeamSession`: forwards companion events, keeps the
/// session's settings and character current, ticks it, and holds an App Nap activity while teammates are online.
@MainActor
final class TeamRuntime {
    static let tickInterval: TimeInterval = 5
    /// No keyboard or mouse input for this long counts as idle (자리비움), with the plaza open or closed.
    static let idleAfter: TimeInterval = 300
    /// The tick only drives heartbeats and the notice batch, so it may coalesce with other wake-ups.
    static let tickTolerance: Duration = .seconds(2)

    let feed: TeamFeedStore
    let session: TeamSession
    weak var plaza: PlazaWindowController?
    /// Set by the app only for a bundled build; nil means no notifications (tests, dev runs).
    var notifier: TeamNotifier?

    private let settings: TeamSettings
    private let companion: CompanionStore
    private let closePlazaOverride: (() -> Void)?
    private let secondsSinceInput: () -> TimeInterval
    private var started = false
    private var wasReady: Bool
    private var lastCode: TeamCode?
    private var tickTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isHoldingActivity: Bool { activity != nil }
    var isTicking: Bool { tickTask != nil }

    init(settings: TeamSettings, companion: CompanionStore, transport: TeamTransporting = BonjourTeamTransport(),
         feed: TeamFeedStore? = nil, closePlaza: (() -> Void)? = nil,
         secondsSinceInput: @escaping () -> TimeInterval = TeamRuntime.systemSecondsSinceInput) {
        self.settings = settings
        self.companion = companion
        self.closePlazaOverride = closePlaza
        self.secondsSinceInput = secondsSinceInput
        let feed = feed ?? TeamFeedStore(myMemberID: settings.memberID)
        self.feed = feed
        wasReady = settings.isReady
        lastCode = settings.code
        session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: {
            Self.profile(settings: settings, companion: companion)
        }, evolutionStage: { [companion] in companion.representativeEvolutionStage })
    }

    func start() {
        guard !started else { return }
        started = true
        companion.onTeamEvent = { [weak session] in session?.publish($0) }
        plaza?.onFocusEnd = { [weak self] in self?.notifier?.focusEnded($0) }
        notifier?.isFocusing = { [weak self] in self?.plaza?.isFocusing ?? false }
        session.onEmote = { [weak self] memberID, emote in
            guard let self else { return }
            if emote.kind.endsSendersDance { plaza?.stopDance(memberID: memberID) }
            if emote.kind == .tackle {
                plaza?.showTackle(from: memberID, on: emote.targetMemberID, tiles: TeamEmote.pushTiles(emote.pushTiles))
                return
            }
            if emote.kind == .jump {
                plaza?.showJump(memberID: memberID)
                return
            }
            if emote.kind == .groupPhoto {
                plaza?.showGroupPhoto(from: memberID)
                return
            }
            if emote.kind == .pickup {
                if let slot = emote.itemSlot { plaza?.showPickup(from: memberID, slot: slot) }
                return
            }
            if emote.kind == .firework {
                plaza?.showFirework(memberID: memberID, style: emote.fireworkStyle)
                return
            }
            if emote.kind == .dance {
                plaza?.showDance(memberID: memberID, style: emote.danceStyle,
                                 since: emote.danceSince.map(Date.init(timeIntervalSince1970:)))
                return
            }
            if emote.kind == .decoyFound {
                plaza?.showDecoyFound(from: memberID, copied: emote.targetMemberID)
                return
            }
            if emote.kind == .decoyTackle {
                plaza?.showDecoyTackle(from: memberID, on: emote.targetMemberID)
                return
            }
            if emote.kind == .pull {
                plaza?.showPull(from: memberID, on: emote.targetMemberID)
                return
            }
            if emote.kind == .decoyJump {
                plaza?.showDecoyJump(from: memberID)
                return
            }
            let overDecoy = emote.overDecoy == true
            plaza?.showEmote(memberID: memberID, kind: emote.kind,
                             alsoOver: emote.isShared == true ? emote.targetMemberID : nil, overDecoy: overDecoy)
            if !overDecoy, emote.targetMemberID == settings.memberID, emote.kind.notifiesTarget,
               let member = session.members[memberID] {
                notifier?.emoteToMe(from: member, kind: emote.kind)
            }
        }
        session.onChat = { [weak self] memberID, text, isLoud in
            guard let self else { return }
            plaza?.stopDance(memberID: memberID)
            plaza?.showChat(memberID: memberID, text: text, isLoud: isLoud)
            if isLoud, let member = session.members[memberID] { notifier?.megaphone(from: member, text: text) }
        }
        session.onBigEvent = { [weak self] event in
            self?.plaza?.showBigEvent(event)
            self?.notifier?.bigEvent(event)
        }
        session.onReactionToMine = { [weak self] reaction, event in
            self?.notifier?.reactionToMine(reaction, event)
        }
        // The character first, so the first hello carries it rather than the fallback.
        observeCharacter()
        observeSettings()
    }

    // MARK: - Observation (re-register first, then work)

    private func observeSettings() {
        withObservationTracking {
            _ = settings.isEnabled
            _ = settings.code
            _ = settings.nickname
            _ = settings.nameColor
            _ = settings.notificationsEnabled
            _ = settings.schedule
            _ = session.hasOnlinePeers
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        session.applySettings()
        plaza?.applySchedule()
        let ready = settings.isReady
        // Notices batched for another team (or for no team) must not be posted later.
        if !ready || settings.code != lastCode {
            notifier?.reset()
            plaza?.endFocusSilently()
        }
        lastCode = settings.code
        if ready {
            startTicking()
            notifier?.requestAuthorizationIfNeeded()
        } else {
            stopTicking()
            if wasReady { closePlaza() }
        }
        // Heartbeats only matter while someone is there to miss them.
        if ready && session.hasOnlinePeers { beginActivityIfNeeded() } else { endActivity() }
        wasReady = ready
    }

    private func observeCharacter() {
        let character = withObservationTracking {
            PlazaRoster.character(entry: PlazaRoster.myEntry(companion: companion, teamSettings: settings),
                                  subject: companion.representativeSubject)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCharacter() }
        }
        session.updateCharacter(character)
    }

    // MARK: - Helpers

    private func closePlaza() {
        if let closePlazaOverride { closePlazaOverride() } else { plaza?.closeIfOpen() }
    }

    /// App Nap would delay the heartbeat until teammates see me disappear. Idle system sleep stays allowed.
    private func beginActivityIfNeeded() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "PokeTokenBar team presence")
    }

    /// Runs only while the team is on, so a feature-off app has no periodic wake-ups.
    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval), tolerance: Self.tickTolerance)
                guard !Task.isCancelled, let self else { return }
                self.tickOnce()
            }
        }
    }

    func tickOnce() {
        session.updateIdle(secondsSinceInput() >= Self.idleAfter)
        session.tick()
        plaza?.endFocusIfDue()
        notifier?.flush()
    }

    /// 마지막 입력 뒤 지난 시간. 권한 없이 읽을 수 있고 어떤 앱을 쓰는지는 알 수 없다.
    nonisolated static func systemSecondsSinceInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                                    .leftMouseDragged, .otherMouseDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    static func profile(settings: TeamSettings, companion: CompanionStore) -> TeamMemberProfile {
        TeamProfileBuilder.profile(
            memberID: settings.memberID, nickname: TeamSettings.validNickname(settings.nickname) ?? "",
            state: companion.state, dexSpecies: companion.teamDexSpecies,
            speciesName: { id in
                companion.currentLine.map {
                    companion.formDisplayName($0.localizedName(id, companion.state.language),
                                              speciesID: id, form: companion.currentForm)
                }
            })
    }
}
