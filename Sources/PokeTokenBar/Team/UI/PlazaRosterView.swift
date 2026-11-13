import SwiftUI
import AppKit

/// 광장 오른쪽 위 참여자 목록(파티 화면 느낌). 칸과 페이지 단추는 누를 수 있고, 키는 받지 않는다.
@MainActor
struct PlazaRosterView: View {
    let model: PlazaRosterModel
    /// 팀원 칸을 누르면 그 팀원의 ID. 내 칸은 누를 수 없다.
    var onSelect: (String) -> Void = { _ in }
    /// < > 를 누르면 넘길 방향(-1, 1).
    var onTurn: (Int) -> Void = { _ in }

    var body: some View {
        let l = L(.ko)
        let entries = model.entries
        let online = entries.filter { $0.presence == .online || $0.presence == .focus }.count
        let page = PlazaRoster.page(entries, index: model.page, size: model.capacity)
        VStack(spacing: 0) {
            HStack {
                Text(l.plazaRosterTitle)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(Color(hex: 0x2D4048))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(hex: 0xF8F8F0), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(l.plazaRosterCount(online: online, total: entries.count))
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(Color(hex: 0xF8F8F0))
                if page.count > 1 {
                    PlazaRosterPager(hasPrevious: page.index > 0, hasNext: page.index < page.count - 1, turn: onTurn)
                }
            }
            .frame(height: PlazaRosterMetrics.headerHeight)
            let layout = PlazaRoster.listLayout(page.shown, hovered: model.hoveredID, maxHeight: model.maxListHeight)
            VStack(spacing: PlazaRosterMetrics.slotSpacing) {
                ForEach(page.shown) { entry in
                    PlazaRosterSlot(entry: entry, animating: model.isAnimating, expanded: model.hoveredID == entry.id,
                                    onHover: { model.hover(entry.id, inside: $0) })
                        .contentShape(Rectangle())
                        .onTapGesture { if !entry.isMe { onSelect(entry.id) } }
                        .help(entry.isMe || entry.presence == .asleep ? "" : L(.ko).plazaRosterWalkHint)
                }
            }
            // 펼친 칸이 작은 지도 밑으로 내려가면 목록을 위로 밀어 그 칸의 아랫줄까지 보이게 한다.
            .offset(y: -layout.scroll)
            .frame(height: layout.height, alignment: .top)
            .clipped()
            .animation(.easeOut(duration: 0.18), value: model.hoveredID)
            .padding(.top, PlazaRosterMetrics.listTopPadding)
        }
        .padding(PlazaRosterMetrics.padding)
        .frame(width: PlazaRosterMetrics.width)
        .background(PlazaRosterBackground())
    }
}

@MainActor
struct PlazaRosterBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x2D7F87)))
            // 135° 줄무늬: 6pt 두께 두 색 교대
            let alt = Color(hex: 0x2A7880)
            var x = -size.height
            var odd = false
            while x < size.width {
                if odd {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + 6, y: 0))
                    p.addLine(to: CGPoint(x: x + 6 + size.height, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: size.height)); p.closeSubpath()
                    ctx.fill(p, with: .color(alt))
                }
                odd.toggle(); x += 6
            }
        }
        .clipShape(shape)
        // 바깥 선(0–3pt)을 먼저 그리고 안쪽 선(3–5pt)을 그 위에 그려 2pt 전체가 보이게 한다.
        .overlay(shape.inset(by: 1.5).stroke(Color(hex: 0x1D4F55), lineWidth: 3))
        .overlay(shape.inset(by: 4).stroke(Color(hex: 0x5FB7BD), lineWidth: 2))
    }
}

extension PlazaPresence {
    /// 상태 칸의 글자와 바탕색. 접속은 초록, 자리비움은 주황, 잠은 보라.
    var badge: (text: String, color: UInt32) {
        let l = L(.ko)
        switch self {
        case .online: return (l.plazaStatusOnline, 0x48B860)
        case .idle: return (l.plazaStatusIdle, 0xD08830)
        case .asleep: return (l.plazaStatusAsleep, 0x9070B8)
        case .focus: return (l.plazaStatusFocus, 0xD9502A)
        }
    }
}

@MainActor
private struct PlazaRosterSlot: View {
    let entry: PlazaRosterEntry
    let animating: Bool
    /// 마우스가 올라와 아래로 펼쳐진 칸. 오늘 광장에서 한 일이 보인다.
    let expanded: Bool
    let onHover: (Bool) -> Void

    private var colors: (top: Color, bottom: Color, border: Color) {
        if entry.presence == .asleep { return (Color(hex: 0x8088A0), Color(hex: 0x707890), Color(hex: 0x3A4050)) }
        if entry.presence == .idle { return (Color(hex: 0xA8B0C0), Color(hex: 0x9098A8), Color(hex: 0x4A5060)) }
        if entry.isMe { return (Color(hex: 0xF8B878), Color(hex: 0xF09858), Color(hex: 0x8A4A28)) }
        return (Color(hex: 0x7CC8E8), Color(hex: 0x5FB0D8), Color(hex: 0x23464C))
    }

    var body: some View {
        let l = L(.ko)
        let c = colors
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                           bottomTrailingRadius: 8, topTrailingRadius: 8)
        // 마우스를 올리면 칸이 그 자리에서 아래로 늘어나 오늘 한 일을 보여 주고, 아래 칸들은 밀려 내려간다. 옆으로는 움직이지 않는다.
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                PlazaRosterIcon(speciesID: entry.speciesID, bounces: (entry.presence == .online || entry.presence == .focus) && animating)
                    .frame(width: 40, height: 30)
                    .padding(.leading, 6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(entry.nickname).lineLimit(1)
                        if let g = genderSymbol { Text(g.text).foregroundStyle(g.color) }
                        if entry.isShiny { Text("★").foregroundStyle(Color(hex: 0xFFE060)) }
                    }
                    .font(Font(PlazaResources.font(.body)))
                    Text(entry.speciesName).lineLimit(1)
                        .font(Font(PlazaResources.font(.body)))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                Spacer(minLength: 0)
                Text(status.text)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(hex: status.color), in: Capsule())
                    .padding(.trailing, 6)
            }
            .frame(height: PlazaRosterMetrics.slotHeight)
            PlazaRosterActivity(activity: entry.activity)
                .frame(height: expanded ? PlazaRosterMetrics.activityHeight(rows: PlazaActivity.rows(entry.activity).count) : 0, alignment: .top)
                .clipped()
        }
        .clipShape(shape)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.18), value: expanded)
        .background(
            VStack(spacing: 0) { c.top.frame(height: PlazaRosterMetrics.slotHeight / 2); c.bottom }.clipShape(shape)   // 위 절반 색은 펼쳐도 그대로
        )
        .overlay(shape.inset(by: 3).stroke(.white.opacity(0.6), lineWidth: 2))
        .overlay(shape.inset(by: 1).stroke(c.border, lineWidth: 2))
    }

    private var status: (text: String, color: UInt32) { entry.presence.badge }

    private var genderSymbol: (text: String, color: Color)? {
        switch entry.gender {
        case .male: return ("♂", Color(hex: 0xA8D8FF))
        case .female: return ("♀", Color(hex: 0xFFB0C8))
        default: return nil
        }
    }
}

/// 펼친 칸 아래에 붙는 오늘 한 일. 줄마다 이름표와 값이고, 기록이 없으면 한 줄이다.
@MainActor
private struct PlazaRosterActivity: View {
    let activity: PlazaActivity?

    var body: some View {
        let rows = PlazaActivity.rows(activity)
        VStack(spacing: PlazaRosterMetrics.activityRowGap) {
            if rows.isEmpty {
                Text(L(.ko).plazaActivityNone).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    Text(row.label).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(row.value).lineLimit(1)
                }
            }
        }
        .font(Font(PlazaResources.font(.small)))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
        .padding(.leading, 18).padding(.trailing, 12)
        .padding(.top, PlazaRosterMetrics.activityTopPadding)
    }
}

/// 머리줄의 < > 단추. 페이지 번호가 없어서, 끝 쪽 단추가 흐려지는 것이 지금 위치를 알려 준다.
@MainActor
private struct PlazaRosterPager: View {
    let hasPrevious: Bool
    let hasNext: Bool
    let turn: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            arrow("<", enabled: hasPrevious, delta: -1)
            arrow(">", enabled: hasNext, delta: 1)
        }
    }

    private func arrow(_ glyph: String, enabled: Bool, delta: Int) -> some View {
        Button { turn(delta) } label: {
            Text(glyph)
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .frame(width: PlazaRosterMetrics.pagerHitSize, height: PlazaRosterMetrics.pagerHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// 박스 아이콘. 받는 동안과 실패했을 때는 빈 자리표시, 알은 알 그림. 접속 중이면 0.5초마다 2pt씩 튄다
/// (애니메이션 없이 정수 위치를 번갈아 바꿔 초당 2번만 다시 그린다).
@MainActor
private struct PlazaRosterIcon: View {
    let speciesID: Int?
    let bounces: Bool
    @State private var image: NSImage?
    @State private var up = false

    /// 페이지를 넘기면 칸이 새로 생긴다. macOS 15 는 `.task` 가 첫 그림 뒤에 도니, 메모리에 있는 아이콘은 여기서 바로 그린다.
    private var cached: NSImage? {
        if let speciesID { return PlazaIconLoader.cachedIcon(speciesID: speciesID) }
        return SpriteLoader.cachedEggImage()
    }

    var body: some View {
        Group {
            if let image = cached ?? image {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.25)).padding(4)
            }
        }
        .offset(y: bounces && up ? -2 : 0)
        .task(id: speciesID) {
            image = nil
            // 실패하면 5초 뒤 한 번 더 시도한다. 뷰가 사라져 취소되면 그림을 넣지 않는다.
            for attempt in 0..<2 {
                let loaded = await load()
                if Task.isCancelled { return }
                if let loaded { image = loaded; return }
                if attempt == 0 {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { return }
                }
            }
        }
        .task(id: bounces) {
            up = false
            guard bounces else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                up.toggle()
            }
        }
    }

    private func load() async -> NSImage? {
        if let id = speciesID { return await PlazaIconLoader.icon(speciesID: id) }
        return await SpriteLoader.eggImage()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 팀원 칸을 누를 수 있게 마우스는 받고, 키는 받지 않아 장면이 계속 받는다.
final class PlazaRosterHostingView: NSHostingView<PlazaRosterView> {
    override var acceptsFirstResponder: Bool { false }
}
