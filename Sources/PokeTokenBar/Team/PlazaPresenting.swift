import Foundation

/// What `TeamRuntime` asks of the plaza window. `PlazaWindowController` (Mac, draws with SpriteKit) conforms in
/// `PlazaPresentingMac.swift`; the shared runtime holds only this protocol.
@MainActor protocol PlazaPresenting: AnyObject {
    var onFocusEnd: ((PlazaFocusEnd) -> Void)? { get set }
    var isFocusing: Bool { get }
    func stopDance(memberID: String)
    func showTackle(from sender: String, on target: String?, tiles: Int)
    func showMimicTackle(from sender: String, on target: String?)
    func showMimicFound(from sender: String, finder: String?)
    func showSnowball(from sender: String, on target: String?, tiles: Int, direction: PlazaDirection?)
    func showJump(memberID: String, iceBreak b: PlazaIceBreak?)
    func showGroupPhoto(from memberID: String)
    func showPickup(from memberID: String, slot: Int)
    func showFirework(memberID: String, style: String?)
    func showDance(memberID: String, style: String?, since: Date?)
    func showDecoyFound(from sender: String, copied: String?)
    func showDecoyTackle(from sender: String, on target: String?)
    func showPull(from sender: String, on target: String?)
    func showDecoyJump(from sender: String)
    func showPray(memberID: String)
    func showEmote(memberID: String, kind: TeamEmoteKind, alsoOver other: String?, overDecoy: Bool)
    func showChat(memberID: String, text: String, isLoud: Bool)
    func showBigEvent(_ e: TeamEvent)
    func applySchedule()
    func endFocusSilently()
    func closeIfOpen()
    func endFocusIfDue()
}
