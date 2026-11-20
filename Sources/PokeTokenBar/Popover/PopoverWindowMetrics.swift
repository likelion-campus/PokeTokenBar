import Foundation

/// Twin of the Mac's `PopoverMetrics` (`UI/PopoverView.swift`, stage 7 D6, D8): the popover's width, padding and scroller
/// lane in the Mac's points, which the Windows kit uses as DIP. `twins.txt` holds the body to the Mac's.
enum PopoverWindowMetrics {
    static let width: CGFloat = 360
    static let padding: CGFloat = 14
    static let contentWidth: CGFloat = width - padding * 2
    static let scrollerInset: CGFloat = 12
    static let scrollContentWidth: CGFloat = contentWidth - scrollerInset
}
