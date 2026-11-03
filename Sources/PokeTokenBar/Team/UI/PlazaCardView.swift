import SwiftUI
import AppKit

/// 카드 판과 그림 크기. 그림은 원본 도트의 1.5배라 Retina 화면에서 도트 하나가 고르게 3픽셀이 된다(광장 캐릭터와 같은 배율).
enum PlazaCardMetrics {
    static let panelSize = CGSize(width: 380, height: 460)
    static let panelInset = PlazaRosterMetrics.padding + 4
    /// 광장 캐릭터. PokéAPI 앞모습(96픽셀)의 1.5배.
    static let spriteSide: CGFloat = 144
    /// 도감 칸의 박스 아이콘. 원본(40x30)의 1.5배.
    static let iconSize = CGSize(width: 60, height: 45)
    static let cellSize = CGSize(width: 64, height: 52)
    static let columns = 5
    static let spacing: CGFloat = 4
}

/// 팀원 카드: 누구의 카드인지, 광장 캐릭터(크게, 이로치·희귀도 표시), 도감 격자(이로치 ★, 전설 표시).
/// 읽기 전용이고 수치(보유 수, 진행률, 희귀도 합계)는 두지 않는다.
@MainActor
struct PlazaCardView: View {
    let state: PlazaCardState

    var body: some View {
        let l = L(.ko)
        VStack(spacing: 8) {
            header
            switch state {
            case .loading:
                message(l.plazaCardLoading)
            case .failed:
                message(l.plazaCardFailed)
            case .loaded(_, let profile):
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(PlazaCardMetrics.cellSize.width), spacing: PlazaCardMetrics.spacing),
                                             count: PlazaCardMetrics.columns),
                              spacing: PlazaCardMetrics.spacing) {
                        ForEach(Array(profile.dex.enumerated()), id: \.offset) { _, species in
                            PlazaDexCell(species: species)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        let l = L(.ko)
        let member = state.member
        return HStack(alignment: .center, spacing: 12) {
            PlazaCardSprite(mon: member.character)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.plazaCardTitle(nickname: member.nickname))
                    .font(Font(PlazaResources.font(size: 16)))
                    .foregroundStyle(Color(cgColor: PlazaNameColor.color(forMemberID: member.memberID, chosen: member.nameColor)))
                    .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let name = state.characterName {
                    Text(name)
                        .font(Font(PlazaResources.font(size: 14)))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                let badges = state.characterBadges
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in PlazaCardPill(badge: badge, size: 12) }
                    }
                }
                if let other = state.differingCurrent { PlazaCardIcon(speciesID: other.speciesID, size: CGSize(width: 40, height: 30)) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: PlazaCardMetrics.spriteSide)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Font(PlazaResources.font(size: 14)))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 이로치는 노란 바탕, 희귀도는 앱의 희귀도 색.
@MainActor
private struct PlazaCardPill: View {
    let badge: PlazaCardBadge
    let size: CGFloat

    var body: some View {
        let l = L(.ko)
        let (text, fill, ink): (String, Color, Color) = switch badge {
        case .shiny: (l.plazaCardShiny, Color(hex: 0xFFE060), Color(hex: 0x2D4048))
        case .rarity(let r): (l.rarityLabel(r), rarityColor(r), .white)
        }
        Text(text)
            .font(Font(PlazaResources.font(size: size)))
            .foregroundStyle(ink)
            .padding(.horizontal, size / 2).padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

@MainActor
private struct PlazaDexCell: View {
    let species: TeamDexSpecies

    var body: some View {
        let legendary = species.rarity == .legendary
        PlazaCardIcon(speciesID: species.speciesID, size: PlazaCardMetrics.iconSize)
            .frame(width: PlazaCardMetrics.cellSize.width, height: PlazaCardMetrics.cellSize.height)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if legendary { RoundedRectangle(cornerRadius: 6).stroke(rarityColor(.legendary), lineWidth: 1.5) }
            }
            .overlay(alignment: .topTrailing) {
                if species.hasShiny {
                    Text("★").font(.system(size: 12)).foregroundStyle(Color(hex: 0xFFE060)).padding(.top, 2).padding(.trailing, 4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if legendary { PlazaCardPill(badge: .rarity(.legendary), size: 10).padding(2) }
            }
            .help(species.name)
    }
}

/// 광장 캐릭터를 크게. 이로치면 이로치 그림이다. 받는 동안과 실패했을 때는 빈 자리표시.
@MainActor
private struct PlazaCardSprite: View {
    let mon: TeamMonSummary
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.25)).padding(36)
            }
        }
        .frame(width: PlazaCardMetrics.spriteSide, height: PlazaCardMetrics.spriteSide)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .task(id: "\(mon.speciesID ?? 0)-\(mon.isShiny)-\(mon.form?.rawValue ?? "")") {
            image = nil
            guard let id = mon.speciesID else { image = await SpriteLoader.eggImage(); return }
            let loaded = await SpriteLoader.image(speciesID: id, shiny: mon.isShiny, form: mon.form)
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// 박스 아이콘 한 칸. 받는 동안과 실패했을 때는 빈 자리표시.
@MainActor
private struct PlazaCardIcon: View {
    let speciesID: Int?
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.25)).padding(4)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: speciesID) {
            image = nil
            guard let id = speciesID else { image = await SpriteLoader.eggImage(); return }
            let loaded = await PlazaIconLoader.icon(speciesID: id)
            if !Task.isCancelled { image = loaded }
        }
    }
}
