import Foundation

// The Windows popover's own wording where the Mac's `L` strings name Mac things (stage 7 D13): Keychain, Finder, macOS,
// the menu bar. Each member is derived from the Mac string it replaces (named in its comment) and changes only what
// differs on Windows; every language the app ships. `Tests/PopoverParity/strings.txt` records each as `replaced:`.
// Several tasks add their members to this file; each task's members sit in its own delimited block.

// --- stage 7 Task 6: Settings essentials (begin) ---
extension L {
    /// `backViewHint`: "Always shows its back in the menu bar, floating pet and popover". The tray icon replaces the menu bar;
    /// the floating pet is not on Windows yet.
    var winBackViewHint: String {
        t("트레이 아이콘·팝오버에서 항상 뒷모습으로 보여요",
          "Always shows its back in the tray icon and popover",
          "トレイアイコン・ポップオーバーで常に後ろ姿になります",
          "Siempre se muestra de espaldas en el icono de la bandeja y el popover",
          "Toujours de dos dans l'icône de la zone de notification et le popover",
          "Sempre de costas no ícone da bandeja e no popover",
          "Zeigt im Tray-Symbol und im Popover immer den Rücken",
          "Всегда показывает спину в значке в области уведомлений и во всплывающем окне")
    }

    /// The Mac's literal "Finder" button (show the log file): Windows' file manager is Explorer.
    var winExplorerButton: String { "Explorer" }

    /// `claudeKeychainHelpTitle`: "Why does it ask for password periodically?" There is no password prompt on Windows; the
    /// same question there is why the limits sometimes need a manual refresh.
    var winClaudeCredentialHelpTitle: String {
        t("왜 가끔 직접 새로고침해야 하나요?",
          "Why do I sometimes have to refresh by hand?",
          "なぜ時々手動で更新する必要があるのですか？",
          "¿Por qué a veces tengo que actualizar a mano?",
          "Pourquoi dois-je parfois actualiser à la main ?",
          "Por que às vezes preciso atualizar manualmente?",
          "Warum muss ich manchmal von Hand aktualisieren?",
          "Почему иногда нужно обновлять вручную?")
    }

    /// `claudeKeychainHelpBody`: "When Claude CLI rotates tokens in the background, macOS resets the Keychain 'Always Allow'
    /// permission. Registering a session key keeps background limits refreshed without any password prompt." On Windows the
    /// token lives in Claude's sign-in file, which the CLI rewrites when it rotates the token.
    var winClaudeCredentialHelpBody: String {
        t("Claude CLI가 백그라운드에서 토큰을 교체하면 Claude 로그인 파일(~/.claude/.credentials.json)이 새로 쓰여요. 새로고침 버튼을 누르면 새 토큰을 다시 읽습니다. 세션 키를 등록하면 그 파일과 상관없이 백그라운드 자동 갱신이 유지됩니다.",
          "When Claude CLI rotates tokens in the background, it rewrites Claude's sign-in file (~/.claude/.credentials.json). Pressing Refresh reads the new token again. Registering a session key keeps background limits refreshed regardless of that file.",
          "Claude CLI がバックグラウンドでトークンをローテーションすると、Claude のサインインファイル（~/.claude/.credentials.json）が書き換えられます。更新ボタンを押すと新しいトークンを読み直します。セッションキーを登録すると、そのファイルに関係なく自動更新が維持されます。",
          "Cuando Claude CLI rota tokens en segundo plano, reescribe el archivo de inicio de sesión de Claude (~/.claude/.credentials.json). Al pulsar Actualizar se lee de nuevo el token. Registrar una clave de sesión mantiene los límites actualizados sin depender de ese archivo.",
          "Lorsque Claude CLI renouvelle les jetons en arrière-plan, il réécrit le fichier de connexion de Claude (~/.claude/.credentials.json). Le bouton Actualiser relit le nouveau jeton. L'enregistrement d'une clé de session permet de maintenir les limites à jour sans dépendre de ce fichier.",
          "Quando o Claude CLI renova tokens em segundo plano, ele reescreve o arquivo de login do Claude (~/.claude/.credentials.json). Ao tocar em Atualizar, o novo token é lido de novo. Cadastrar uma chave de sessão mantém a atualização automática sem depender desse arquivo.",
          "Wenn Claude CLI Tokens im Hintergrund erneuert, schreibt es die Anmeldedatei von Claude (~/.claude/.credentials.json) neu. Mit „Aktualisieren“ wird das neue Token erneut gelesen. Ein registrierter Sitzungsschlüssel hält Limits unabhängig von dieser Datei aktuell.",
          "Когда Claude CLI в фоне обновляет токены, он перезаписывает файл входа Claude (~/.claude/.credentials.json). Кнопка «Обновить» заново читает новый токен. Если добавить ключ сессии, лимиты будут обновляться в фоне независимо от этого файла.")
    }

    /// `claudeKeychainHelpTooltip`: "Claude Keychain authentication info".
    var winClaudeCredentialHelpTooltip: String {
        t("Claude 로그인 파일 안내",
          "Claude sign-in file info",
          "Claude サインインファイルについて",
          "Información del archivo de inicio de sesión de Claude",
          "Info sur le fichier de connexion Claude",
          "Informações do arquivo de login do Claude",
          "Claude-Anmeldedatei-Information",
          "О файле входа Claude")
    }

    /// `reportMailBody`: the Mac's text with "macOS" and `~/Library/Logs/PokeTokenBar.log` replaced by Windows and the log
    /// file's place there (`%LOCALAPPDATA%\PokeTokenBar\Logs`, `PlatformCompat.logsDirectory`). Nothing else differs.
    func winReportMailBody(version: String, os: String) -> String {
        let log = #"%LOCALAPPDATA%\PokeTokenBar\Logs\PokeTokenBar.log"#
        return t("""
        문제 내용:
        (겪으신 문제를 적어주세요 — 언제, 어떤 화면에서, 어떻게 되었는지)


        ---
        앱 버전: v\(version)
        Windows: \(os)
        로그 파일(첨부 권장): \(log)
        """,
        """
        What happened:
        (Describe the problem — when, on which screen, and what you saw)


        ---
        App version: v\(version)
        Windows: \(os)
        Log file (please attach): \(log)
        """,
        """
        問題の内容:
        （いつ・どの画面で・どうなったかをご記入ください）


        ---
        アプリのバージョン: v\(version)
        Windows: \(os)
        ログファイル（添付推奨）: \(log)
        """,
        """
        Descripción del problema:
        (Describe lo que ocurrió — cuándo, en qué pantalla y qué viste)


        ---
        Versión de la app: v\(version)
        Windows: \(os)
        Archivo de registro (se recomienda adjuntar): \(log)
        """,
        """
        Ce qui s'est passé :
        (Décris le problème — quand, sur quel écran, et ce que tu as vu)


        ---
        Version de l'app : v\(version)
        Windows: \(os)
        Fichier journal (à joindre de préférence) : \(log)
        """,
        """
        Descrição do problema:
        (Descreva o que aconteceu — quando, em qual tela e o que você viu)


        ---
        Versão do app: v\(version)
        Windows: \(os)
        Arquivo de log (anexe, por favor): \(log)
        """,
        """
        Was ist passiert:
        (Beschreibe das Problem – wann, auf welchem Bildschirm und was du gesehen hast)


        ---
        App-Version: v\(version)
        Windows: \(os)
        Protokolldatei (bitte anhängen): \(log)
        """,
        """
        Что произошло:
        (Опишите проблему — когда, на каком экране и что вы увидели)


        ---
        Версия приложения: v\(version)
        Windows: \(os)
        Файл журнала (приложите, пожалуйста): \(log)
        """)
    }
}
// --- stage 7 Task 6: Settings essentials (end) ---

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

// --- stage 7 Task 15: difficulty, backup and transfer (begin) ---
extension L {
    /// `importSaveHint`: "Pick a file exported from another Mac and continue here". A save is exported by the Mac app or by
    /// this app on another computer.
    var winImportSaveHint: String {
        t("다른 컴퓨터의 PokeTokenBar에서 내보낸 파일을 골라 이 PC에서 이어서 키워요",
          "Pick a file exported from PokeTokenBar on another computer and continue here",
          "別のコンピューターの PokeTokenBar から書き出したファイルを選んで、この PC で続けます",
          "Elige un archivo exportado desde PokeTokenBar en otro equipo y continúa aquí",
          "Choisis un fichier exporté depuis PokeTokenBar sur un autre ordinateur et continue ici",
          "Escolha um arquivo exportado do PokeTokenBar em outro computador e continue por aqui",
          "Wähle eine in PokeTokenBar auf einem anderen Computer exportierte Datei aus und mach hier weiter",
          "Выберите файл, экспортированный из PokeTokenBar на другом компьютере, и продолжайте здесь")
    }

    /// `importConfirmTitle`: "Replace this Mac's progress?"
    var winImportConfirmTitle: String {
        t("이 PC의 진행을 대체할까요?",
          "Replace this PC's progress?",
          "この PC の進行を置き換えますか？",
          "¿Reemplazar el progreso de este PC?",
          "Remplacer la progression de ce PC ?",
          "Substituir o progresso deste PC?",
          "Fortschritt auf diesem PC ersetzen?",
          "Заменить прогресс на этом ПК?")
    }

    /// `importConfirmBody`: the Mac's text with "this Mac" said as "this PC". The promise that the previous state is kept as a
    /// backup is the same (the import refuses to apply when the backup cannot be written).
    func winImportConfirmBody(incomingDex: Int, incomingTokens: String,
                              exportedAt: String, sourceDevice: String,
                              currentDex: Int, currentTokens: String) -> String {
        t("""
          불러올 세이브: 도감 \(incomingDex)마리 · 누적 \(incomingTokens)
          내보낸 시각: \(exportedAt) · \(sourceDevice)
          현재 이 PC: 도감 \(currentDex)마리 · 누적 \(currentTokens)

          이 PC의 현재 진행은 대체됩니다. 직전 상태는 상태 폴더에 백업으로 남습니다(최근 5개).
          """,
          """
          Incoming save: \(incomingDex) in Pokédex · \(incomingTokens) lifetime
          Exported: \(exportedAt) · \(sourceDevice)
          This PC now: \(currentDex) in Pokédex · \(currentTokens) lifetime

          This PC's current progress is replaced. The previous state is kept as a backup in the state folder (last 5).
          """,
          """
          読み込むセーブ: 図鑑 \(incomingDex)匹 · 累計 \(incomingTokens)
          書き出し日時: \(exportedAt) · \(sourceDevice)
          現在のこの PC: 図鑑 \(currentDex)匹 · 累計 \(currentTokens)

          この PC の現在の進行は置き換えられます。直前の状態は状態フォルダーにバックアップとして残ります（最新5件）。
          """,
          """
          Partida a importar: Pokédex \(incomingDex) · \(incomingTokens) acumulados
          Exportada: \(exportedAt) · \(sourceDevice)
          Este PC ahora: Pokédex \(currentDex) · \(currentTokens) acumulados

          El progreso actual de este PC será reemplazado. El estado anterior se guarda como copia de seguridad en la carpeta de estado (últimas 5).
          """,
          """
          Sauvegarde à importer : Pokédex \(incomingDex) · \(incomingTokens) cumulés
          Exportée : \(exportedAt) · \(sourceDevice)
          Ce PC actuellement : Pokédex \(currentDex) · \(currentTokens) cumulés

          La progression actuelle de ce PC sera remplacée. L'état précédent est conservé en sauvegarde dans le dossier d'état (5 derniers).
          """,
          """
          Save a ser importado: Pokédex \(incomingDex) · \(incomingTokens) acumulados
          Exportado: \(exportedAt) · \(sourceDevice)
          Este PC agora: Pokédex \(currentDex) · \(currentTokens) acumulados

          O progresso atual deste PC será substituído. O estado anterior fica guardado como backup na pasta de estado (últimos 5).
          """,
          """
          Zu importierender Spielstand: \(incomingDex) im Pokédex · \(incomingTokens) insgesamt
          Exportiert: \(exportedAt) · \(sourceDevice)
          Dieser PC jetzt: \(currentDex) im Pokédex · \(currentTokens) insgesamt

          Der aktuelle Fortschritt auf diesem PC wird ersetzt. Der vorherige Stand bleibt als Sicherung im Statusordner erhalten (die letzten 5).
          """,
          """
          Импортируемое сохранение: Покедекс \(incomingDex) · \(incomingTokens) за всё время
          Экспортировано: \(exportedAt) · \(sourceDevice)
          Сейчас на этом ПК: Покедекс \(currentDex) · \(currentTokens) за всё время

          Текущий прогресс на этом ПК будет заменён. Предыдущее состояние останется резервной копией в папке состояния (последние 5).
          """)
    }

    /// The file type's name in the file dialogs ("JSON (*.json)").
    var winSaveFileFilterName: String {
        t("세이브 파일 (*.json)",
          "Save file (*.json)",
          "セーブファイル (*.json)",
          "Archivo de partida (*.json)",
          "Fichier de sauvegarde (*.json)",
          "Arquivo de save (*.json)",
          "Spielstanddatei (*.json)",
          "Файл сохранения (*.json)")
    }
}
// --- stage 7 Task 15: difficulty, backup and transfer (end) ---
