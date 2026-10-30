import SwiftUI
import AppKit

/// 설정 화면의 "팀" 섹션 — SettingsView 의 섹션 카드 룩을 따른다.
@MainActor
struct TeamSettingsSection: View {
    @Environment(TeamSettings.self) private var team
    @Environment(TeamSession.self) private var session: TeamSession?
    private let l = L(.ko)
    @State private var joinDraft = ""
    @State private var joinFailed = false

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
                            Text(masked(code)).font(.callout.monospaced())
                            Spacer()
                            Button(l.teamCopyCode) { copy(code) }
                            Button(l.teamLeave, role: .destructive) { team.leaveTeam() }
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
                    }
                    Divider()
                    row {
                        Text(l.teamNickname)
                        TextField(l.teamNickname, text: $team.nickname)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    }
                    if TeamSettings.validNickname(team.nickname) == nil {
                        error(l.teamNicknameInvalid)
                    }
                    Divider()
                    row {
                        Text(l.teamNotifications)
                        Spacer()
                        Toggle(l.teamNotifications, isOn: $team.notificationsEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
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

    private func join() {
        if let parsed = TeamCode(parsing: joinDraft) {
            team.code = parsed
            joinDraft = ""
            joinFailed = false
        } else {
            joinFailed = true
        }
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
