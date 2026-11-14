import Foundation

/// The Windows tray menu as plain values (the Mac's `StatusItemMenu` counterpart, which lives in `UI/`), so tests can
/// pin the contents without a window. `nil` entries are separators.
enum TrayMenuModel {
    enum Action: Equatable { case none, toggleLaunchAtLogin, openLogFolder, openRelease, refresh, quit }

    struct Item: Equatable {
        let title: String
        let enabled: Bool
        let checked: Bool
        let action: Action
    }

    enum LoginState: Equatable { case on, off, disabledByUser, unavailable }

    /// The shell shows at most 127 UTF-16 units of a tooltip (`szTip` is 128 including the terminator).
    static let tipLimit = 127

    /// `update` is the version of an available release (Task 10 supplies it); nil hides the entry.
    static func items(l: L, todayTokens: Int, todayCost: UsageCost?, login: LoginState, update: String?) -> [Item?] {
        let loginItem: Item
        switch login {
        case .on:
            loginItem = Item(title: l.launchAtLogin, enabled: true, checked: true, action: .toggleLaunchAtLogin)
        case .off:
            loginItem = Item(title: l.launchAtLogin, enabled: true, checked: false, action: .toggleLaunchAtLogin)
        case .disabledByUser:
            loginItem = Item(title: "\(l.launchAtLogin) (\(l.disabledInTaskManager))", enabled: false, checked: false,
                             action: .toggleLaunchAtLogin)
        case .unavailable:
            loginItem = Item(title: l.launchAtLogin, enabled: false, checked: false, action: .toggleLaunchAtLogin)
        }
        var rows: [Item?] = [
            Item(title: summary(l: l, todayTokens: todayTokens, todayCost: todayCost), enabled: false, checked: false,
                 action: .none),
            nil,
            Item(title: l.refreshNow, enabled: true, checked: false, action: .refresh),
            loginItem,
            Item(title: l.openLogFolder, enabled: true, checked: false, action: .openLogFolder),
        ]
        if let update {
            rows.append(Item(title: l.updateFound(update), enabled: true, checked: false, action: .openRelease))
        }
        rows.append(nil)
        rows.append(Item(title: l.quit, enabled: true, checked: false, action: .quit))
        return rows
    }

    /// "Today's tokens 19.4M · $5.09"; the cost is left out when no provider reports one (same as the popover header).
    static func summary(l: L, todayTokens: Int, todayCost: UsageCost?) -> String {
        let tokens = "\(l.todayTokens) \(TokenFormatter.compact(todayTokens))"
        guard let todayCost else { return tokens }
        return "\(tokens) · \(todayCost.text(l))"
    }

    /// The icon's tooltip: today's numbers, then the tracked-account note when the store has one.
    static func tooltip(l: L, todayTokens: Int, todayCost: UsageCost?, note: String?) -> String {
        let line = summary(l: l, todayTokens: todayTokens, todayCost: todayCost)
        return clipped(note.map { "\(line)\n\($0)" } ?? line)
    }

    /// At most `maxUnits` UTF-16 units, cut on a character boundary (never inside a surrogate pair), with "…" when cut.
    static func clipped(_ text: String, maxUnits: Int = tipLimit) -> String {
        guard text.utf16.count > maxUnits else { return text }
        var out = ""
        var units = 0
        for character in text {
            let n = character.utf16.count
            if units + n > maxUnits - 1 { break }
            out.append(character)
            units += n
        }
        return out + "…"
    }
}

/// Tray strings in every app language. (`launchAtLogin`, `refreshNow`, `quit`, `updateFound` already exist.)
extension L {
    var disabledInTaskManager: String {
        t("작업 관리자에서 꺼짐", "Disabled in Task Manager", "タスク マネージャーで無効", "Desactivado en el Administrador de tareas",
          "Désactivé dans le Gestionnaire des tâches", "Desativado no Gerenciador de Tarefas", "Im Task-Manager deaktiviert",
          "Отключено в диспетчере задач")
    }
    var openLogFolder: String {
        t("로그 폴더 열기", "Open log folder", "ログフォルダーを開く", "Abrir carpeta de registros", "Ouvrir le dossier des journaux",
          "Abrir pasta de logs", "Protokollordner öffnen", "Открыть папку журналов")
    }
    var trayFirstRunHint: String {
        t("PokeTokenBar가 알림 영역에서 실행 중이에요. 아이콘이 안 보이면 ^ 를 눌러 숨겨진 아이콘을 열고 작업 표시줄로 끌어다 놓으세요.",
          "PokeTokenBar is running in the notification area. If you don't see the icon, click ^ to show hidden icons and drag it onto the taskbar.",
          "PokeTokenBar は通知領域で実行中です。アイコンが見えない場合は ^ をクリックして隠れているアイコンを表示し、タスク バーにドラッグしてください。",
          "PokeTokenBar se está ejecutando en el área de notificación. Si no ves el icono, haz clic en ^ para mostrar los iconos ocultos y arrástralo a la barra de tareas.",
          "PokeTokenBar s'exécute dans la zone de notification. Si l'icône n'est pas visible, cliquez sur ^ pour afficher les icônes masquées et faites-la glisser vers la barre des tâches.",
          "O PokeTokenBar está em execução na área de notificação. Se não vir o ícone, clique em ^ para mostrar os ícones ocultos e arraste-o para a barra de tarefas.",
          "PokeTokenBar läuft im Infobereich. Wenn das Symbol fehlt, klicke auf ^, um ausgeblendete Symbole anzuzeigen, und ziehe es auf die Taskleiste.",
          "PokeTokenBar работает в области уведомлений. Если значка не видно, нажмите ^, чтобы показать скрытые значки, и перетащите его на панель задач.")
    }
    var alreadyRunning: String {
        t("이미 실행 중이에요", "Already running", "すでに実行中です", "Ya se está ejecutando", "Déjà en cours d'exécution",
          "Já está em execução", "Läuft bereits", "Уже запущено")
    }
}
