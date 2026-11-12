import SwiftUI
import AppKit

/// 설정 화면의 "팀" 섹션 — SettingsView 의 섹션 카드 룩을 따른다.
@MainActor
struct TeamSettingsSection: View {
    @Environment(TeamSettings.self) private var team
    @Environment(TeamSession.self) private var session: TeamSession?
    @Environment(PopoverNavigation.self) private var nav: PopoverNavigation?
    private let l = L(.ko)
    @State private var joinDraft = ""
    @State private var joinFailed = false
    /// The nickname being typed; the stored one changes only on submit or focus loss, and only when valid.
    @State private var nicknameDraft: String?
    @State private var teamNameDraft: String?
    @FocusState private var nicknameFocused: Bool
    /// 코드로 참여했지만 닉네임이 아직 없다. 닉네임을 정하는 순간 광장을 연다.
    @State private var openPlazaWhenReady = false

    var body: some View {
        @Bindable var team = team
        VStack(alignment: .leading, spacing: 6) {
            Text(l.teamSectionTitle)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .textCase(.uppercase).padding(.leading, 4)
            VStack(spacing: 0) {
                row {
                    Text(l.teamEnable)
                    Spacer()
                    Toggle(l.teamEnable, isOn: $team.isEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if team.isEnabled {
                    Divider()
                    if let code = team.code {
                        row {
                            Text(masked(code)).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            Button(l.teamCopyCode) { copy(code) }
                            Button(l.teamLeave, role: .destructive) { team.leaveTeam() }
                        }
                        Divider()
                        row {
                            Text(l.teamName)
                            TextField(l.teamName, text: Binding(get: { teamNameDraft ?? team.currentTeam?.name ?? "" },
                                                                set: { teamNameDraft = $0 }))
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                .onSubmit(commitTeamName)
                                .onDisappear(perform: commitTeamName)
                        }
                        Divider()
                        row {
                            Text(l.teamSwitch)
                            Spacer()
                            Menu(team.currentTeam?.name ?? l.teamSwitch) {
                                ForEach(team.savedTeams) { saved in
                                    Button(saved.name) { switchTo(saved) }
                                        .disabled(saved.code == code.normalized)
                                }
                                Divider()
                                Button(l.teamStepOut) { team.stepOut() }
                            }
                            .fixedSize()
                        }
                    } else {
                        row {
                            Button(l.teamCreate) {
                                var rng = SystemRandomNumberGenerator()
                                team.code = TeamCode.generate(using: &rng)
                            }
                            Spacer()
                        }
                        Divider()
                        row {
                            TextField(l.teamCodePlaceholder, text: $joinDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(join)
                            Button(l.teamJoin, action: join)
                        }
                        if joinFailed {
                            error(l.teamCodeInvalid)
                        }
                        ForEach(team.savedTeams) { saved in
                            Divider()
                            row {
                                Text(l.teamSaved).foregroundStyle(.secondary)
                                Text(saved.name).lineLimit(1)
                                Spacer()
                                Button(l.teamEnterSaved) { switchTo(saved) }
                            }
                        }
                    }
                    Divider()
                    row {
                        Text(l.teamNickname)
                        TextField(l.teamNickname, text: Binding(get: { nicknameDraft ?? team.nickname },
                                                                set: { nicknameDraft = $0 }))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .focused($nicknameFocused)
                            .onSubmit(commitNickname)
                            .onChange(of: nicknameFocused) { _, focused in if !focused { commitNickname() } }
                            // Closing settings or the popover is not guaranteed to move focus first.
                            .onDisappear(perform: commitNickname)
                    }
                    if TeamSettings.validNickname(nicknameDraft ?? team.nickname) == nil {
                        error(l.teamNicknameInvalid)
                    }
                    Divider()
                    row {
                        Text(l.teamNotifications)
                        Spacer()
                        Toggle(l.teamNotifications, isOn: $team.notificationsEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if team.code != nil {
                        Divider()
                        scheduleRows
                    }
                    if session?.hasIncompatiblePeer == true {
                        error(l.teamIncompatiblePeer)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }

    private var scheduleRows: some View {
        let core = team.schedule?.coreTime ?? .standard
        let period = team.schedule?.period ?? .day
        func change(_ start: Int, _ end: Int, _ period: PlazaWeather.Period) {
            team.changeSchedule(coreStart: start, coreEnd: end, period: period, now: Date())
        }
        return VStack(spacing: 0) {
            row {
                Text(l.teamCoreTime)
                Spacer()
                Picker(l.teamCoreTime, selection: Binding(get: { core.start }, set: { change($0, core.end, period) })) {
                    ForEach(1...22, id: \.self) { Text(l.teamHour($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text("~")
                Picker(l.teamCoreTime, selection: Binding(get: { core.end }, set: { change(core.start, $0, period) })) {
                    ForEach((core.start + 1)...23, id: \.self) { Text(l.teamHour($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text(scheduleCaption)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var scheduleCaption: String {
        guard let s = team.schedule, let name = TeamSettings.validNickname(s.changedByName) else {
            return l.teamScheduleDefaultCaption
        }
        return l.teamScheduleChangedCaption(name: name, when: l.teamScheduleDate(s.changedAt))
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 38)
    }

    private func error(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func commitTeamName() {
        guard let draft = teamNameDraft else { return }
        if team.renameCurrentTeam(draft) { teamNameDraft = nil }
    }

    private func switchTo(_ saved: TeamSettings.SavedTeam) {
        commitTeamName()
        teamNameDraft = nil
        team.switchTo(saved)
    }

    private func commitNickname() {
        nicknameDraft = Self.committedDraft(nicknameDraft, into: team)
        if openPlazaWhenReady && team.isReady {
            openPlazaWhenReady = false
            nav?.onOpenPlaza?()
        }
    }

    /// Stores a valid draft and returns nil (nothing left to edit). An invalid draft keeps the stored name and
    /// stays as it is, so the message stays up until the field is fixed.
    static func committedDraft(_ draft: String?, into team: TeamSettings) -> String? {
        guard let draft else { return nil }
        return team.commitNickname(draft) ? nil : draft
    }

    enum JoinResult: Equatable { case invalid, openPlaza, needsNickname }

    /// 코드가 맞으면 그 팀에 들어간다. 팀이 바로 준비되면 광장을 열고, 닉네임이 없으면 닉네임을 정할 때까지 미룬다.
    static func join(_ draft: String, into team: TeamSettings) -> JoinResult {
        guard let parsed = TeamCode(parsing: draft) else { return .invalid }
        team.code = parsed
        return team.isReady ? .openPlaza : .needsNickname
    }

    private func join() {
        let result = Self.join(joinDraft, into: team)
        joinFailed = result == .invalid
        guard result != .invalid else { return }
        joinDraft = ""
        if result == .openPlaza { nav?.onOpenPlaza?() } else { openPlazaWhenReady = true }
    }

    /// "PTB-ABCDE-…" 중 앞 한 묶음만 보이게 나머지를 가린다.
    private func masked(_ code: TeamCode) -> String {
        let parts = code.display.split(separator: "-").map(String.init)
        return parts.enumerated().map { $0.offset <= 1 ? $0.element : String(repeating: "•", count: $0.element.count) }
            .joined(separator: "-")
    }

    private func copy(_ code: TeamCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.display, forType: .string)
    }
}
