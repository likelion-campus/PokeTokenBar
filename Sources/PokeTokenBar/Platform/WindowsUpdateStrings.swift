import Foundation

/// The Windows in-app update's texts in every app language (stage 8 Task 6): its progress window and its balloons. Shared so
/// the placeholder check runs on both systems; only Windows shows them.
extension L {
    func updateDownloading(_ version: String) -> String {
        t("v\(version) 내려받는 중…", "Downloading version \(version)…", "バージョン \(version) をダウンロード中…",
          "Descargando la versión \(version)…", "Téléchargement de la version \(version)…", "Baixando a versão \(version)…",
          "Version \(version) wird heruntergeladen…", "Загрузка версии \(version)…")
    }
    var updateChecking: String {
        t("내려받은 파일을 확인하는 중…", "Checking the download…", "ダウンロードしたファイルを確認中…", "Comprobando la descarga…",
          "Vérification du téléchargement…", "Verificando o download…", "Download wird geprüft…", "Проверка загрузки…")
    }
    var updateStartingSetup: String {
        t("설치 프로그램을 시작해요. 앱이 잠시 닫혔다가 다시 열려요.", "Starting the installer. The app closes and opens again.",
          "インストーラーを起動します。アプリはいったん閉じてから再び開きます。", "Iniciando el instalador. La app se cerrará y volverá a abrirse.",
          "Lancement du programme d’installation. L’app se ferme puis se rouvre.", "Iniciando o instalador. O app fecha e abre de novo.",
          "Das Installationsprogramm startet. Die App wird geschlossen und wieder geöffnet.",
          "Запуск установщика. Приложение закроется и откроется снова.")
    }
    /// After a failed download or check (the release page opens with it), and at the start after Setup put the previous app back.
    var updateInstallFailed: String {
        t("업데이트를 설치하지 못했어요. 릴리스 페이지에서 직접 설치해 주세요.",
          "The update couldn't be installed. Please install it from the release page.",
          "アップデートをインストールできませんでした。リリースページから直接インストールしてください。",
          "No se pudo instalar la actualización. Instálala desde la página de la versión.",
          "La mise à jour n’a pas pu être installée. Installe-la depuis la page de la version.",
          "Não foi possível instalar a atualização. Instale-a pela página da versão.",
          "Das Update konnte nicht installiert werden. Bitte installiere es über die Release-Seite.",
          "Не удалось установить обновление. Установите его со страницы релиза.")
    }
    var updateSetupRunning: String {
        t("다른 PokeTokenBar 설치 프로그램이 실행 중이에요. 그 설치를 끝낸 뒤 다시 업데이트해 주세요.",
          "Another PokeTokenBar installer is running. Finish it, then update again.",
          "別の PokeTokenBar インストーラーが実行中です。それを終えてから、もう一度アップデートしてください。",
          "Hay otro instalador de PokeTokenBar en ejecución. Termínalo y vuelve a actualizar.",
          "Un autre programme d’installation de PokeTokenBar est en cours. Termine-le, puis relance la mise à jour.",
          "Outro instalador do PokeTokenBar está em execução. Conclua-o e atualize de novo.",
          "Ein anderes PokeTokenBar-Installationsprogramm läuft. Schließe es ab und aktualisiere dann erneut.",
          "Уже запущен другой установщик PokeTokenBar. Завершите его и обновите снова.")
    }
}
