import Foundation

// Words the Windows popover says that the Mac's `L` has no member for (stage 7 D13): where the Mac's text names a Mac thing
// (Keychain, Finder, "this Mac") or the Windows page needs a line the Mac's layout carries in other ways. Named `win…`, all
// eight languages, the pattern of `TrayMenuModel.swift`. Each task adds its own block between its own markers.

// --- stage 7 Task 5: the Home page (begin) ---
extension L {
    /// Under the totals while no provider has reported any usage (first run): says what fills the page.
    var winNoUsageYet: String {
        t("아직 사용량이 없어요. Claude Code, Codex 같은 AI 도구를 쓰면 여기에 오늘의 토큰이 나타나요.",
          "No usage yet. Use an AI tool such as Claude Code or Codex and today's tokens show up here.",
          "まだ使用量がありません。Claude Code や Codex などの AI ツールを使うと、今日のトークンがここに表示されます。",
          "Aún no hay uso. Usa una herramienta de IA como Claude Code o Codex y los tokens de hoy aparecerán aquí.",
          "Aucune utilisation pour l'instant. Utilisez un outil d'IA comme Claude Code ou Codex et les jetons du jour s'afficheront ici.",
          "Ainda não há uso. Use uma ferramenta de IA como o Claude Code ou o Codex e os tokens de hoje aparecem aqui.",
          "Noch keine Nutzung. Verwende ein KI-Tool wie Claude Code oder Codex, dann erscheinen die heutigen Tokens hier.",
          "Пока нет данных. Используйте ИИ-инструмент, например Claude Code или Codex, и токены за сегодня появятся здесь.")
    }
}
// --- stage 7 Task 5: the Home page (end) ---
