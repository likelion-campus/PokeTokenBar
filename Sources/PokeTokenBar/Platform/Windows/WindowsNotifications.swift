#if os(Windows)
import Foundation

/// The Windows `LocalNotifying`: app notifications (limit alerts, companion events) as tray balloons. A balloon needs
/// no OS consent, so `requestAuthorization` only reports whether the tray icon exists (no prompt is ever shown).
/// Windows may still suppress a balloon (Focus Assist, notifications turned off for the app) while the API succeeds.
@MainActor final class WindowsNotifications: LocalNotifying {
    let presenter: WinBalloonPresenter
    private let tray: WinTray

    init(presenter: WinBalloonPresenter, tray: WinTray) {
        self.presenter = presenter
        self.tray = tray
    }

    var isAvailable: Bool { tray.isPresent }

    func requestAuthorization() async -> Bool { true }

    func post(id: String, title: String, body: String, sound: Bool) {
        presenter.post(.init(id: id, title: title, body: body, sound: sound, kind: .app))
    }

    /// Replaces the stub notifier in `Platform.current` once the tray exists (the platform is built before it).
    static func install(presenter: WinBalloonPresenter, tray: WinTray) {
        let current = Platform.current
        Platform.current = Platform(notifications: WindowsNotifications(presenter: presenter, tray: tray),
                                    secrets: current.secrets, events: current.events, idle: current.idle)
    }
}
#endif
