import Foundation
import Observation

// The HUD toggles' models, read by the Mac's SwiftUI views (`Team/UI/PlazaChatLogView.swift`,
// `Team/UI/PlazaShortcutGuideView.swift`) and written by the shared controller.

@MainActor @Observable
final class PlazaBackgroundModel {
    var isHidden = false
}

@MainActor @Observable
final class PlazaNameColorModel {
    /// 지금 이름표 색(RGB). 고르지 않았으면 멤버 ID의 색.
    var current: UInt32 = PlazaNameColor.hexes[0]
    var isOpen = false
}

@MainActor @Observable
final class PlazaShortcutGuideModel {
    var isFolded = false
    var season = PlazaSeason.winter
}
