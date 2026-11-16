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

// --- stage 7 Task 14: session keys and advanced settings (begin) ---
extension L {
    /// `sessionKeyHint`: "Fetches official limits with no Keychain pop-up. Paste the value from DevTools → …". There is no
    /// Keychain on Windows; what the key saves a Windows user is the dependence on Claude's sign-in file (an expired token in
    /// it stops the limits until Claude Code runs again).
    var winSessionKeyHint: String {
        t("Claude 로그인 파일 없이 공식 한도를 조회합니다. 브라우저 개발자도구 → Application → Cookies → claude.ai → sessionKey 값을 붙여넣으세요.",
          "Fetches official limits without Claude's sign-in file. Paste the value from DevTools → Application → Cookies → claude.ai → sessionKey.",
          "Claude のサインインファイルなしで公式上限を取得します。開発者ツール → Application → Cookies → claude.ai → sessionKey の値を貼り付けてください。",
          "Obtiene los límites oficiales sin el archivo de inicio de sesión de Claude. Pega el valor de DevTools → Application → Cookies → claude.ai → sessionKey.",
          "Récupère les limites officielles sans le fichier de connexion de Claude. Colle la valeur depuis DevTools → Application → Cookies → claude.ai → sessionKey.",
          "Busca os limites oficiais sem o arquivo de login do Claude. Cole o valor de DevTools → Application → Cookies → claude.ai → sessionKey.",
          "Ruft offizielle Limits ohne die Anmeldedatei von Claude ab. Füge den Wert aus DevTools → Application → Cookies → claude.ai → sessionKey ein.",
          "Загружает официальные лимиты без файла входа Claude. Вставьте значение из DevTools → Application → Cookies → claude.ai → sessionKey.")
    }

    /// `sessionKeyStorageNote`: "The key is stored in this Mac's app folder as an owner-only file (not encrypted). Logging out in
    /// your browser invalidates it immediately." Windows keeps it encrypted for the Windows account (DPAPI, D14).
    var winSessionKeyStorageNote: String {
        t("키는 이 PC의 앱 폴더에 Windows 계정용으로 암호화되어 저장됩니다. 브라우저에서 로그아웃하면 즉시 무효화됩니다.",
          "The key is stored in this PC's app folder, encrypted for your Windows account. Logging out in your browser invalidates it immediately.",
          "キーはこの PC のアプリフォルダに、Windows アカウント用に暗号化して保存されます。ブラウザでログアウトすると即時無効になります。",
          "La clave se guarda en la carpeta de la app de este PC, cifrada para tu cuenta de Windows. Al cerrar sesión en el navegador se invalida de inmediato.",
          "La clé est enregistrée dans le dossier de l'app sur ce PC, chiffrée pour ton compte Windows. Te déconnecter dans le navigateur l'invalide immédiatement.",
          "A chave fica na pasta do app neste PC, criptografada para a sua conta do Windows. Sair da conta no navegador a invalida na hora.",
          "Der Schlüssel liegt im App-Ordner dieses PCs, verschlüsselt für dein Windows-Konto. Meldest du dich im Browser ab, wird er sofort ungültig.",
          "Ключ хранится в папке приложения на этом ПК, зашифрованным для вашей учётной записи Windows. Выход из аккаунта в браузере сразу делает его недействительным.")
    }

    /// `refreshLimitToken`: "Refresh limit token cache" (the Mac reads the Keychain). Windows reads Claude's sign-in file again (D12).
    var winRefreshLimitToken: String {
        t("Claude 로그인 정보 다시 읽기", "Reload Claude sign-in", "Claude のサインイン情報を再読み込み", "Volver a leer el inicio de sesión de Claude",
          "Relire la connexion Claude", "Ler de novo o login do Claude", "Claude-Anmeldung neu lesen", "Перечитать вход Claude")
    }

    /// `onlyOnPress`: "Reads Keychain only when pressed — auto-polling never does, so no pop-ups. Refresh limits here after the
    /// token expires". Windows reads the sign-in file on every refresh anyway (no prompt); the button reads it again now.
    var winOnlyOnPress: String {
        t("Claude 로그인 파일(~/.claude/.credentials.json)을 지금 다시 읽어요. 토큰 만료 후 이 버튼으로 한도 갱신",
          "Reads Claude's sign-in file (~/.claude/.credentials.json) again right now. Refresh limits here after the token expires",
          "Claude のサインインファイル（~/.claude/.credentials.json）を今すぐ読み直します。トークン期限切れ後はこのボタンで上限を更新",
          "Vuelve a leer ahora el archivo de inicio de sesión de Claude (~/.claude/.credentials.json). Usa este botón para actualizar los límites tras la expiración del token",
          "Relit maintenant le fichier de connexion de Claude (~/.claude/.credentials.json). Actualise les limites ici après l'expiration du token",
          "Lê de novo agora o arquivo de login do Claude (~/.claude/.credentials.json). Use este botão para atualizar os limites depois que o token expirar",
          "Liest die Anmeldedatei von Claude (~/.claude/.credentials.json) sofort neu. Aktualisiere die Limits hier, wenn das Token abgelaufen ist",
          "Сразу перечитывает файл входа Claude (~/.claude/.credentials.json). Обновите лимиты здесь, когда токен истечёт")
    }

    /// `additionalClaudeAccountsHint`, without its last clause ("a manual refresh may ask for Keychain access for each folder")
    /// and with "the CLAUDE_CONFIG_DIR environment variable" for "an exported CLAUDE_CONFIG_DIR" (no login shell on Windows: the
    /// variable is read from the environment, `UsageEnvironment.value`).
    var winAdditionalClaudeAccountsHint: String {
        t("다른 Claude Code 로그인(CLAUDE_CONFIG_DIR)은 ~/.claude-* 폴더와 CLAUDE_CONFIG_DIR 환경 변수에서 자동으로 찾습니다. 다른 위치의 설정 폴더만 여기 추가하세요(콤마·줄바꿈 구분). 공식 한도에 계정마다 탭이 생깁니다.",
          "Other Claude Code logins (CLAUDE_CONFIG_DIR) are detected in ~/.claude-* folders and from the CLAUDE_CONFIG_DIR environment variable. Add config folders stored elsewhere here, comma/newline separated. Each account gets its own tab in the official limits.",
          "他のClaude Codeログイン(CLAUDE_CONFIG_DIR)は ~/.claude-* フォルダと環境変数 CLAUDE_CONFIG_DIR から自動検出されます。別の場所にある設定フォルダだけをここに追加してください(カンマ・改行区切り)。公式上限にアカウントごとのタブが追加されます。",
          "Los otros inicios de sesión de Claude Code (CLAUDE_CONFIG_DIR) se detectan en las carpetas ~/.claude-* y en la variable de entorno CLAUDE_CONFIG_DIR. Añade aquí las carpetas de configuración guardadas en otro lugar, separadas por coma o salto de línea. Cada cuenta tiene su pestaña en los límites oficiales.",
          "Les autres connexions Claude Code (CLAUDE_CONFIG_DIR) sont détectées dans les dossiers ~/.claude-* et depuis la variable d'environnement CLAUDE_CONFIG_DIR. Ajoute ici les dossiers de config rangés ailleurs, séparés par des virgules ou des retours à la ligne. Chaque compte a son onglet dans les limites officielles.",
          "Os outros logins do Claude Code (CLAUDE_CONFIG_DIR) são detectados nas pastas ~/.claude-* e na variável de ambiente CLAUDE_CONFIG_DIR. Adicione aqui pastas de configuração guardadas em outro lugar, separadas por vírgula ou quebra de linha. Cada conta ganha sua aba nos limites oficiais.",
          "Weitere Claude-Code-Anmeldungen (CLAUDE_CONFIG_DIR) werden in ~/.claude-*-Ordnern und über die Umgebungsvariable CLAUDE_CONFIG_DIR erkannt. Füge hier Konfigurationsordner an anderen Orten hinzu, durch Kommas oder Zeilenumbrüche getrennt. Jedes Konto bekommt bei den offiziellen Limits einen eigenen Tab.",
          "Другие входы в Claude Code (CLAUDE_CONFIG_DIR) находятся автоматически в папках ~/.claude-* и по переменной окружения CLAUDE_CONFIG_DIR. Папки конфигурации в других местах добавьте здесь — через запятую или с новой строки. У каждого аккаунта своя вкладка в официальных лимитах.")
    }

    /// `trackedAccountHint`: "Drives the menu bar limit, warning state, companion mood and 5h forecast." The tray icon shows no
    /// limit (P17): the rest stays.
    var winTrackedAccountHint: String {
        t("경고 상태·컴패니언 기분·5시간 예측의 기준이에요.",
          "Drives the warning state, companion mood and 5h forecast.",
          "警告状態・コンパニオンの様子・5時間予測に使われます。",
          "Define el estado de alerta, el ánimo del compañero y la previsión de 5 h.",
          "Pilote l'état d'alerte, l'humeur du compagnon et la prévision 5 h.",
          "Define o estado de alerta, o humor do companheiro e a previsão de 5 h.",
          "Bestimmt den Warnstatus, die Stimmung des Begleiters und die 5-Stunden-Prognose.",
          "Определяет предупреждения, настроение компаньона и прогноз на 5 ч.")
    }
}
// --- stage 7 Task 14: session keys and advanced settings (end) ---
