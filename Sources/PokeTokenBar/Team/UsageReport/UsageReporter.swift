import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

protocol UsageReportTransport: Sendable {
    /// Posts the body and returns the reply body, whatever the HTTP status.
    func post(_ body: Data) async throws -> Data
}

/// The real transport. The sheet answers with a 302 that both URLSession and WinHTTP follow as a GET.
struct HTTPUsageReportTransport: UsageReportTransport {
    func post(_ body: Data) async throws -> Data {
        var request = URLRequest(url: UsageReportConfig.endpoint, timeoutInterval: UsageReportConfig.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await PlatformCompat.oneShotData(for: request)
        return data
    }
}

struct UsageReportInputs {
    var snapshots: [ProviderSnapshot]
    var claudeAccounts: [ClaudeAccountLimits]
    var codex: CodexRateLimitStatus?
    var codexReadAt: Date?

    @MainActor static func from(_ store: UsageStore) -> UsageReportInputs {
        UsageReportInputs(snapshots: store.snapshots, claudeAccounts: store.claudeAccounts,
                          codex: store.codexLimits, codexReadAt: store.codexLimitsUpdatedAt)
    }
}

/// Sends daily token counts and weekly limits to the company sheet while the team feature is on.
@MainActor @Observable
final class UsageReporter {
    private(set) var lastSentAt: Date?
    /// Counts the settings changes the observation has dealt with. Tests wait on it.
    private(set) var settingsChangesHandled = 0
    /// Replaces the loop's sleep in tests; it receives the duration the loop asks for.
    @ObservationIgnored var sleepForTesting: (@MainActor @Sendable (Duration) async -> Void)?

    @ObservationIgnored private let settings: TeamSettings
    @ObservationIgnored private let ledger: UsageReportLedger
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let platform: String
    @ObservationIgnored private let inputs: @MainActor () -> UsageReportInputs
    @ObservationIgnored private let transport: any UsageReportTransport
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastAttemptAt: Date?
    /// What the observation last saw: the stamp is the team presence belongs to until the next change.
    @ObservationIgnored private var armed: (ready: Bool, stamp: UsageReportLedger.TeamStamp?) = (false, nil)

    var isLoopRunning: Bool { loopTask != nil }

    init(settings: TeamSettings, defaults: UserDefaults, appVersion: String, platform: String,
         inputs: @escaping @MainActor () -> UsageReportInputs,
         transport: any UsageReportTransport = HTTPUsageReportTransport(),
         now: @escaping @MainActor () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.settings = settings
        self.ledger = UsageReportLedger(defaults: defaults, timeZone: timeZone)
        self.appVersion = appVersion
        self.platform = platform
        self.inputs = inputs
        self.transport = transport
        self.now = now
        self.timeZone = timeZone
        lastSentAt = ledger.lastSentAt
    }

    // MARK: - Lifecycle

    /// Call once, when the app launches.
    func start() {
        let time = now()
        observe()
        ledger.recordPresence(now: time, team: armed.stamp)
        if armed.ready {
            ledger.teamTurnedOn(now: time)
            ledger.markReady(now: time)
            startLoop()
        } else {
            ledger.teamTurnedOff(now: time)
        }
    }

    /// Re-registers first, then reads, so a change during the work is not missed.
    private func observe() {
        let seen = withObservationTracking {
            (ready: settings.isReady, stamp: currentStamp())
        } onChange: { [weak self] in
            Task { @MainActor in self?.settingsChanged() }
        }
        armed = (seen.ready, seen.stamp)
    }

    private func currentStamp() -> UsageReportLedger.TeamStamp? {
        guard settings.isReady, let code = settings.code else { return nil }
        return .init(id: code.usageTeamID, label: settings.currentTeam?.name ?? "")
    }

    private func settingsChanged() {
        let before = armed
        observe()
        let time = now()
        // The ledger credits the time since its last record to the team of that record, which is the team
        // as it was before this change; the new stamp starts the next stretch.
        ledger.recordPresence(now: time, team: armed.stamp)
        if before.ready && !armed.ready {
            ledger.teamTurnedOff(now: time)
            stopLoop()
        } else if !before.ready && armed.ready {
            ledger.teamTurnedOn(now: time)
            ledger.markReady(now: time)
            startLoop()
        }
        settingsChangesHandled += 1
    }

    // MARK: - Loop

    /// Runs only while the team is on. It holds the reporter weakly while it sleeps, and each cycle it
    /// sleeps until the next send is due, so an attempt made by a refresh does not push the loop a period late.
    private func startLoop() {
        let sleeper = sleepForTesting
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let duration = self?.nextSleep() else { return }
                if let sleeper {
                    await sleeper(duration)
                } else {
                    try? await Task.sleep(for: duration, tolerance: .seconds(60))
                }
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// Until `lastAttemptAt + interval` on the injected clock, the whole interval when nothing was attempted yet,
    /// and never less than a second so an overdue send cannot spin the loop.
    private func nextSleep() -> Duration {
        let interval = UsageReportPlanner.sendInterval(memberID: settings.memberID)
        guard let last = lastAttemptAt else { return .seconds(interval) }
        return .seconds(max(last.addingTimeInterval(interval).timeIntervalSince(now()), 1))
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Sending

    @discardableResult
    func storeRefreshed() -> Task<Void, Never> {
        recordPresence()
        return Task { @MainActor [weak self] in await self?.maybeSend() }
    }

    func tick() async {
        recordPresence()
        await maybeSend()
    }

    private func recordPresence() {
        ledger.recordPresence(now: now(), team: currentStamp())
    }

    private func maybeSend() async {
        guard settings.isReady, let code = settings.code,
              let nickname = TeamSettings.validNickname(settings.nickname), !inFlight else { return }
        let time = now()
        let interval = UsageReportPlanner.sendInterval(memberID: settings.memberID)
        if let last = lastAttemptAt, time.timeIntervalSince(last) < interval { return }
        inFlight = true
        lastAttemptAt = time
        defer { inFlight = false }

        let teamID = code.usageTeamID
        let source = inputs()
        let current = UsageReportLedger.TeamStamp(id: teamID, label: settings.currentTeam?.name ?? "")
        let range = UsageReportPlanner.dayRange(now: time, timeZone: timeZone, firstDay: ledger.firstDay)
        let days = UsageReportPlanner.changed(
            UsageReportPlanner.days(range: range, tools: UsageReportPlanner.tools(from: source.snapshots),
                                    dayTeams: ledger.dayTeams, current: current,
                                    offPeriods: ledger.offPeriods, now: time, timeZone: timeZone),
            sent: ledger.sentDays)
        let candidates = source.claudeAccounts.compactMap {
            UsageReportPlanner.claudeLimit($0, memberID: settings.memberID, team: teamID)
        } + [UsageReportPlanner.codexLimit(source.codex, readAt: source.codexReadAt,
                                           memberID: settings.memberID, team: teamID)].compactMap { $0 }
        let limits = UsageReportPlanner.newLimits(candidates, sent: ledger.sentLimits)

        let body = UsageReportBody(
            v: UsageReportConfig.version, token: UsageReportConfig.token,
            member: .init(id: settings.memberID, secret: ledger.secret, nickname: nickname,
                          appVersion: appVersion, platform: platform),
            days: days, limits: limits.map(\.limit))
        do {
            let reply = try await transport.post(UsageReportBody.encoded(body))
            switch UsageReportResponse.parse(reply) {
            case .accepted(_, _, let dropped):
                let sentAt = now()
                ledger.commit(days: Dictionary(uniqueKeysWithValues: days.map { ($0.date, UsageReportBody.fingerprint($0)) }),
                              limits: Dictionary(limits.map { ($0.key, $0.readAt) }) { max($0, $1) }, at: sentAt)
                lastSentAt = sentAt
                AppLog.write("usage report sent: days=\(days.count) limits=\(limits.count) dropped=\(dropped)")
            case .rejected(let reason):
                AppLog.write("usage report rejected: \(reason)")
            case .notJSON:
                AppLog.write("usage report failed: the reply was not JSON")
            }
        } catch {
            AppLog.write("usage report failed: \(type(of: error))")
        }
    }
}
