import Foundation

/// Where a vertically scrolling panel's content is in its viewport (Track A Task 17a), for the roster, chat log, board
/// and card: the content is `content` points tall, the window onto it `viewport`, and `offset` is how far the content's
/// top is above the viewport's top (0 ... `maxOffset`). It works in points and knows no text, so any panel uses it.
///
/// Wheel input mirrors what a SwiftUI `ScrollView` did inside the plaza window: a delta moves the content while it can
/// move that way and is passed on (not consumed) when the content is at that end or fits the viewport. Where SwiftUI's
/// scroll view stretches past an end and springs back, this clamps: nothing overshoots.
struct PlazaScrollState: Equatable, Sendable {
    private(set) var content: CGFloat = 0
    private(set) var viewport: CGFloat = 0
    private(set) var offset: CGFloat = 0

    init() {}

    var maxOffset: CGFloat { max(0, content - viewport) }
    var canScroll: Bool { maxOffset > 0 }
    var isAtTop: Bool { offset <= 0 }
    var isAtBottom: Bool { offset >= maxOffset }

    /// The content or the viewport changed size (a resize, a new line): the offset stays where it is, kept inside the new
    /// range.
    mutating func setMetrics(content: CGFloat, viewport: CGFloat) {
        self.content = max(0, content)
        self.viewport = max(0, viewport)
        offset = min(max(offset, 0), maxOffset)
    }

    /// `ScrollViewProxy.scrollTo(last, anchor: .bottom)`: the content's end meets the viewport's end.
    mutating func scrollToBottom() { offset = maxOffset }

    /// `NSEvent.scrollingDeltaY` as the system sends it (natural scrolling already applied: positive moves the content
    /// down, so the offset falls; momentum events are applied like any other). True when the event is consumed: the
    /// offset moved. False (pass it on) when it could not move that way, whatever the delta's size.
    @discardableResult
    mutating func scroll(deltaY dy: CGFloat) -> Bool {
        let target = min(max(offset - dy, 0), maxOffset)
        guard target != offset else { return false }
        offset = target
        return true
    }

    /// The indices of the rows (`frames` in content points, top to bottom) that show in the viewport at all.
    func visibleRows(_ frames: [CGRect]) -> Range<Int> {
        guard let first = frames.firstIndex(where: { $0.maxY > offset }),
              let last = frames.lastIndex(where: { $0.minY < offset + viewport }), first <= last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// `rect` (content points) in the viewport's points, cut to the viewport; nil when none of it shows.
    func visible(_ rect: CGRect, offset snapped: CGFloat? = nil) -> CGRect? {
        let o = snapped ?? offset
        let r = rect.offsetBy(dx: 0, dy: -o).intersection(CGRect(x: rect.minX, y: 0, width: rect.width, height: viewport))
        return r.isNull || r.height <= 0 ? nil : r
    }
}
