import Foundation

/// Ties the companion and the team settings to the `TeamSession`: forwards companion events, keeps the
/// session's settings and character current, ticks it, and holds an App Nap activity while the team is on.
@MainActor
final class TeamRuntime {
    static let tickInterval: TimeInterval = 5

    let feed: TeamFeedStore
    let session: TeamSession
    weak var plaza: PlazaWindowController?
    /// Set by the app only for a bundled build; nil means no notifications (tests, dev runs).
    var notifier: TeamNotifier?

    private let settings: TeamSettings
    private let companion: CompanionStore
    private let closePlazaOverride: (() -> Void)?
    private var started = false
    private var wasReady: Bool
    private var tickTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isHoldingActivity: Bool { activity != nil }
    var isTicking: Bool { tickTask != nil }

    init(settings: TeamSettings, companion: CompanionStore, transport: TeamTransporting = BonjourTeamTransport(),
         feed: TeamFeedStore? = nil, closePlaza: (() -> Void)? = nil) {
        self.settings = settings
        self.companion = companion
        self.closePlazaOverride = closePlaza
        let feed = feed ?? TeamFeedStore(myMemberID: settings.memberID)
        self.feed = feed
        wasReady = settings.isReady
        session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: {
            Self.profile(settings: settings, companion: companion)
        })
    }

    func start() {
        guard !started else { return }
        started = true
        companion.onTeamEvent = { [weak session] in session?.publish($0) }
        session.onEmote = { [weak self] memberID, emote in
            guard let self else { return }
            plaza?.showEmote(memberID: memberID, kind: emote.kind)
            if emote.targetMemberID == settings.memberID, emote.kind.notifiesTarget,
               let member = session.members[memberID] {
                notifier?.emoteToMe(from: member, kind: emote.kind)
            }
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
            _ = settings.notificationsEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        session.applySettings()
        let ready = settings.isReady
        if ready {
            beginActivityIfNeeded()
            startTicking()
            notifier?.requestAuthorizationIfNeeded()
        } else {
            endActivity()
            stopTicking()
            if wasReady { closePlaza() }
        }
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
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard let self else { return }
                self.tickOnce()
            }
        }
    }

    func tickOnce() {
        session.tick()
        notifier?.flush()
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

    private static func profile(settings: TeamSettings, companion: CompanionStore) -> TeamMemberProfile {
        TeamProfileBuilder.profile(
            memberID: settings.memberID, nickname: TeamSettings.validNickname(settings.nickname) ?? "",
            state: companion.state, dexSpecies: companion.dexSpecies,
            speciesName: { id in
                companion.currentLine.map {
                    companion.formDisplayName($0.localizedName(id, companion.state.language),
                                              speciesID: id, form: companion.currentForm)
                }
            })
    }
}
