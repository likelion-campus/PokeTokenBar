import SwiftUI
import AppKit

/// 광장 오른쪽 위 참여자 목록(파티 화면 느낌). 표시만 하고 입력은 받지 않는다.
struct PlazaRosterView: View {
    let model: PlazaRosterModel

    var body: some View {
        let l = L(.ko)
        let entries = model.entries
        let online = entries.filter { $0.presence == .online }.count
        VStack(spacing: 0) {
            HStack {
                Text(l.plazaRosterTitle)
                    .font(Font(PlazaResources.font(size: 12)))
                    .foregroundStyle(Color(hex: 0x2D4048))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(hex: 0xF8F8F0), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text(l.plazaRosterCount(online: online, total: entries.count))
                    .font(Font(PlazaResources.font(size: 11)))
                    .foregroundStyle(Color(hex: 0xF8F8F0))
            }
            VStack(spacing: 4) {
                ForEach(entries) { PlazaRosterSlot(entry: $0) }
            }
            .padding(.top, 6)
        }
        .padding(10)
        .frame(width: PlazaRosterMetrics.width)
        .background(PlazaRosterBackground())
    }
}

private struct PlazaRosterBackground: View {
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
        .overlay(shape.inset(by: 3.5).stroke(Color(hex: 0x5FB7BD), lineWidth: 2))
        .overlay(shape.inset(by: 1.5).stroke(Color(hex: 0x1D4F55), lineWidth: 3))
    }
}

private struct PlazaRosterSlot: View {
    let entry: PlazaRosterEntry

    private var colors: (top: Color, bottom: Color, border: Color) {
        if entry.presence == .away { return (Color(hex: 0xA8B0C0), Color(hex: 0x9098A8), Color(hex: 0x4A5060)) }
        if entry.isMe { return (Color(hex: 0xF8B878), Color(hex: 0xF09858), Color(hex: 0x8A4A28)) }
        return (Color(hex: 0x7CC8E8), Color(hex: 0x5FB0D8), Color(hex: 0x23464C))
    }

    var body: some View {
        let l = L(.ko)
        let c = colors
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                           bottomTrailingRadius: 8, topTrailingRadius: 8)
        HStack(spacing: 4) {
            PlazaRosterIcon(speciesID: entry.speciesID, bounces: entry.presence == .online)
                .frame(width: 40, height: 30)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(entry.nickname).lineLimit(1)
                    if let g = genderSymbol { Text(g.text).foregroundStyle(g.color) }
                    if entry.isShiny { Text("★").foregroundStyle(Color(hex: 0xFFE060)) }
                }
                .font(Font(PlazaResources.font(size: 12)))
                Text(entry.speciesName).lineLimit(1)
                    .font(Font(PlazaResources.font(size: 10)))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
            Spacer(minLength: 0)
            Text(entry.presence == .online ? l.plazaStatusOnline : l.plazaStatusAway)
                .font(Font(PlazaResources.font(size: 10)))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(hex: entry.presence == .online ? 0x48B860 : 0x9070B8), in: Capsule())
                .padding(.trailing, 6)
        }
        .frame(height: 44)
        .background(
            VStack(spacing: 0) { c.top; c.bottom }.clipShape(shape)
        )
        .overlay(shape.inset(by: 3).stroke(.white.opacity(0.6), lineWidth: 2))
        .overlay(shape.inset(by: 1).stroke(c.border, lineWidth: 2))
    }

    private var genderSymbol: (text: String, color: Color)? {
        switch entry.gender {
        case .male: return ("♂", Color(hex: 0xA8D8FF))
        case .female: return ("♀", Color(hex: 0xFFB0C8))
        default: return nil
        }
    }
}

/// 박스 아이콘. 받는 동안과 실패했을 때는 빈 자리표시. 접속 중이면 0.5초마다 2pt씩 튄다.
private struct PlazaRosterIcon: View {
    let speciesID: Int?
    let bounces: Bool
    @State private var image: NSImage?
    @State private var up = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.25)).padding(4)
            }
        }
        .offset(y: bounces && up ? -2 : 0)
        .task(id: speciesID) {
            image = nil
            guard let id = speciesID else { return }
            image = await PlazaIconLoader.icon(speciesID: id)
        }
        .onAppear { startBounce() }
        .onChange(of: bounces) { _, _ in startBounce() }
    }

    private func startBounce() {
        if bounces {
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: true)) { up = true }
        } else {
            withAnimation(nil) { up = false }
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 마우스·키를 장면에 그대로 넘기는 호스팅 뷰.
final class PlazaRosterHostingView: NSHostingView<PlazaRosterView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
