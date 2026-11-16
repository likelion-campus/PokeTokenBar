import Foundation

/// Text the Backup & transfer rows and dialogs show (stage 7 Task 15, G16).
enum PopoverTransferFormat {
    /// 확인창에 보일 내보낸 시각 — 사용자 로케일 기준 짧은 표기. (The shared twin of `SettingsView.exportedAtText`, held to
    /// it by `twins.txt`: the exported-at time in the confirmation and the snapshot rows, in the user's language.)
    static func exportedAtText(_ date: Date, language: AppLanguage) -> String {
        let f = DateFormatter()
        f.locale = language.displayLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
