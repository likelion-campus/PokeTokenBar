import Foundation

/// The evolution line's geometry: the shared twin of `EvoLineView`'s statics and scroll state (stage 7 Task 9, twins.txt).
/// The stored values are the view's (`nodes`, `thumb`, `names`, `maxWidth`, the scroll offset and the measured width), so
/// each member's body reads as the Mac's; `PopoverTwinEquivalenceTests+Mac` drives both over the Mac's own corpus. The
/// constants are the view's private ones (held to the Mac's source by the same test).
struct EvoLineLayout: Equatable {
    var nodes: [EvoLineItem]
    var thumb: CGFloat = 40
    var names: [Int: String]? = nil
    var maxWidth: CGFloat = .infinity
    /// The horizontal scroll offset (the Mac's `@State scrollX`).
    var scrollX: CGFloat = 0
    /// The rendered row's width, 0 before it is measured (the Mac's `@State contentWidth`).
    var contentWidth: CGFloat = 0

    static let spacing: CGFloat = 2
    /// 화살표 칸 폭 = 썸네일 × 이 비율.
    static let arrowRatio: CGFloat = 0.25
    /// 이름 라벨이 썸네일보다 넓어질 수 있는 최대치.
    static let nameSlack: CGFloat = 6
    static let fadeWidth: CGFloat = 24

    /// 한 줄이 차지하는 가로 폭. 레이아웃과 같은 식을 쓰는 순수 함수.
    static func rowWidth(count: Int, thumb: CGFloat, hasNames: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        let column = thumb + (hasNames ? nameSlack : 0)
        let arrows = CGFloat(count - 1) * thumb * arrowRatio
        let gaps = CGFloat(2 * count - 2) * spacing
        return CGFloat(count) * column + arrows + gaps
    }

    /// 스크롤 컨테이너가 필요한가 — 한 줄이 `maxWidth` 를 넘는가.
    static func needsScroll(count: Int, thumb: CGFloat, hasNames: Bool, maxWidth: CGFloat) -> Bool {
        guard maxWidth.isFinite, maxWidth > 0 else { return false }
        return rowWidth(count: count, thumb: thumb, hasNames: hasNames) > maxWidth
    }

    /// 어느 쪽에 스크롤 여지가 남았는지 — 페이드와 셰브론이 공유하는 순수 판정.
    static func scrollAffordance(scrollX: CGFloat, contentWidth: CGFloat,
                                 maxWidth: CGFloat) -> (back: Bool, forward: Bool) {
        guard contentWidth > maxWidth + 0.5 else { return (false, false) }
        return (scrollX > 0.5, scrollX < contentWidth - maxWidth - 0.5)
    }

    /// 페이드/셰브론 판정에 쓸 한 줄 폭. 측정 전(첫 프레임)엔 rowWidth 추정치를 쓴다.
    var effectiveContentWidth: CGFloat {
        contentWidth > 0 ? contentWidth
                         : Self.rowWidth(count: nodes.count, thumb: thumb, hasNames: names != nil)
    }
    var canScrollBack: Bool {
        Self.scrollAffordance(scrollX: scrollX, contentWidth: effectiveContentWidth,
                              maxWidth: maxWidth).back
    }
    var canScrollForward: Bool {
        Self.scrollAffordance(scrollX: scrollX, contentWidth: effectiveContentWidth,
                              maxWidth: maxWidth).forward
    }

    func pageTarget(forward: Bool) -> Int {
        Self.pageTarget(forward: forward, scrollX: scrollX, count: nodes.count,
                        thumb: thumb, hasNames: names != nil, maxWidth: maxWidth)
    }

    /// 셰브론 한 번에 이동할 칸 인덱스 — 왼쪽 끝 칸에서 "한 화면에 보이는 칸 수"만큼 앞/뒤로.
    static func pageTarget(forward: Bool, scrollX: CGFloat, count: Int,
                           thumb: CGFloat, hasNames: Bool, maxWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let stride = thumb + (hasNames ? nameSlack : 0) + thumb * arrowRatio + spacing * 2
        let visible = max(1, Int(maxWidth / stride))
        let first = max(0, Int((scrollX / stride).rounded()))
        return min(max(0, first + (forward ? visible : -visible)), count - 1)
    }

    /// Which dex page a node opens (the dex links are tier 3: the header passes none, so no node links on Windows yet).
    static func dexLinkTarget(for node: EvoLineItem, links: [Int: String]) -> String? {
        guard case .species(let id) = node.content else { return nil }
        return links[id]
    }

    // MARK: beyond the Mac's members (Windows: where things are)

    /// One column's width (the thumbnail, plus the name label's slack).
    var column: CGFloat { thumb + (names == nil ? 0 : Self.nameSlack) }
    /// From one column's leading edge to the next.
    var columnStride: CGFloat { column + thumb * Self.arrowRatio + Self.spacing * 2 }
    /// Column `i`'s leading edge in the row (before scrolling).
    func columnX(_ i: Int) -> CGFloat { CGFloat(i) * columnStride }
    /// The arrow before column `i` (`i` ≥ 1): its cell's leading edge.
    func arrowX(_ i: Int) -> CGFloat { columnX(i) - Self.spacing - thumb * Self.arrowRatio }
    var scrolls: Bool { Self.needsScroll(count: nodes.count, thumb: thumb, hasNames: names != nil, maxWidth: maxWidth) }
    /// The width the line takes: the row, or `maxWidth` when it scrolls.
    var visibleWidth: CGFloat { scrolls ? maxWidth : Self.rowWidth(count: nodes.count, thumb: thumb, hasNames: names != nil) }
    /// The farthest the line scrolls.
    var maxScrollX: CGFloat { max(0, effectiveContentWidth - maxWidth) }
    /// The offset after a chevron press: column `pageTarget(forward:)` at the leading edge (the Mac's `scrollTo(_, anchor:
    /// .leading)`, clamped to the content so the last press lands exactly at the end).
    func scrolled(forward: Bool) -> CGFloat {
        min(maxScrollX, max(0, columnX(pageTarget(forward: forward))))
    }
}
