import Foundation

/// The toggle race of a tray flyout (stage 7 D3). A click on the tray icon while the popover is open first takes the
/// activation away (the taskbar is clicked), which closes the popover, and only then does the shell report the click
/// (`NIN_SELECT`): without this, that click would open it again at once. So a close by deactivation with the cursor on the
/// icon is remembered, and a select within `window` of it is that same click: it does not reopen. One click is absorbed
/// once. The Windows SDK's NotificationIcon sample solves the same race with a `GetDoubleClickTime()` timer; this is a
/// timestamp, so nothing wakes. Times are seconds on any monotonic clock. Shared so it is tested on both systems.
struct PopoverToggleGuard: Equatable {
    /// Windows' default double-click time.
    static let window: TimeInterval = 0.5
    /// When the primary button was still down at the close: the taskbar takes the activation on the press and the shell
    /// reports the click on the release, which a slow click (or ClickLock) holds past `window`.
    static let heldWindow: TimeInterval = 3

    /// When the popover was last closed by a deactivation with the cursor on the icon, until a select uses it up.
    private(set) var closedOnIconAt: TimeInterval?
    /// That close came with the primary button down.
    private(set) var closedWithButtonDown = false

    init() {}

    /// The popover lost the activation and closed; `cursorInAnchor`: the cursor was on the icon at that moment;
    /// `buttonDown`: the primary mouse button was still pressed.
    mutating func noteClosedByDeactivation(at time: TimeInterval, cursorInAnchor: Bool, buttonDown: Bool = false) {
        closedOnIconAt = cursorInAnchor ? time : nil
        closedWithButtonDown = cursorInAnchor && buttonDown
    }

    /// Whether a select at `time` opens the popover: false within `window` (`heldWindow` for a press still down) of a close
    /// caused by a click on the icon.
    func opensOnSelect(at time: TimeInterval) -> Bool {
        guard let closed = closedOnIconAt else { return true }
        let elapsed = time - closed
        return !(elapsed >= 0 && elapsed < (closedWithButtonDown ? Self.heldWindow : Self.window))
    }

    /// A select was handled (it opened the popover, closed it, or was absorbed as the closing click).
    mutating func noteSelect() {
        closedOnIconAt = nil
        closedWithButtonDown = false
    }
}
