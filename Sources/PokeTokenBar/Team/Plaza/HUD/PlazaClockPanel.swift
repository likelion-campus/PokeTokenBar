import Foundation

/// The clock on the minimap: the time of day and this computer's time ("밤 21:34"), `PlazaClock` before Track A
/// Task 14. The controller's 1 s tick hands it the text; it changes (and so renders) at most once a minute. It takes no
/// clicks.
@MainActor final class PlazaClockPanel: PlazaPanel {
    let id = PlazaPanelID.clock
    let anchor = PlazaPanelAnchor.bottomTrailing
    let offset: CGPoint
    var onChange: (() -> Void)?
    private(set) var text = ""

    /// `worldSize` is the plaza map's size, which the minimap under the clock is scaled from.
    init(worldSize: CGSize) {
        let room = PlazaPanelStyle.strokeRoom
        offset = CGPoint(x: PlazaRosterMetrics.margin - room,
                         y: PlazaPanelStyle.minimapBottom + PlazaPanelStyle.minimapHeight(worldSize: worldSize)
                            + PlazaPanelStyle.clockAboveMinimap - room)
    }

    /// Reports a change only when the text is new.
    func update(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        onChange?()
    }

    var isVisible: Bool { !text.isEmpty }

    private func pill(_ scale: CGFloat, _ text: any PlazaTextEngine) -> PlazaPill {
        .oneLine(self.text, style: PlazaPanelStyle.clock, maxTextWidth: .greatestFiniteMagnitude, scale: scale, text: text)
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        let s = pill(scale, text).frame.size
        return CGSize(width: s.width + 2 * PlazaPanelStyle.strokeRoom, height: s.height + 2 * PlazaPanelStyle.strokeRoom)
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaImage? {
        var p = pill(scale, graphics.text)
        let room = PlazaPanelStyle.strokeRoom
        p.frame.origin = CGPoint(x: room, y: room)
        return PlazaPill.image([p], size: CGSize(width: p.frame.width + 2 * room, height: p.frame.height + 2 * room),
                               scale: scale, graphics: graphics)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
