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

    /// When the popover was last closed by a deactivation with the cursor on the icon, until a select uses it up.
    private(set) var closedOnIconAt: TimeInterval?

    init() {}

    /// The popover lost the activation and closed; `cursorInAnchor`: the cursor was on the icon at that moment.
    mutating func noteClosedByDeactivation(at time: TimeInterval, cursorInAnchor: Bool) {
        closedOnIconAt = cursorInAnchor ? time : nil
    }

    /// Whether a select at `time` opens the popover: false within `window` of a close caused by a click on the icon.
    func opensOnSelect(at time: TimeInterval) -> Bool {
        guard let closed = closedOnIconAt else { return true }
        let elapsed = time - closed
        return !(elapsed >= 0 && elapsed < Self.window)
    }

    /// A select was handled (it opened the popover, closed it, or was absorbed as the closing click).
    mutating func noteSelect() {
        closedOnIconAt = nil
    }
}
