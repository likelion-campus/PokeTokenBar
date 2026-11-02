import SwiftUI
import AppKit

/// 팀원 카드: 닉네임, 광장 캐릭터, 도감 격자. 읽기 전용이고 수치(보유 수, 진행률, 희귀도 합계)는 두지 않는다.
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
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 6), spacing: 4) {
                        ForEach(Array(profile.dex.enumerated()), id: \.offset) { _, species in
                            PlazaDexCell(species: species)
                        }
                    }
                }
            }
        }
    }

    private var member: TeamMemberState {
        switch state {
        case .loading(let m), .loaded(let m, _), .failed(let m): m
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            PlazaCardIcon(speciesID: member.character.speciesID)
            if let other = state.differingCurrent { PlazaCardIcon(speciesID: other.speciesID) }
            Text(member.nickname).lineLimit(1)
                .font(Font(PlazaResources.font(size: 16)))
                .foregroundStyle(Color(cgColor: PlazaNameColor.color(forMemberID: member.memberID)))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
            Spacer(minLength: 0)
        }
        .frame(height: 36)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Font(PlazaResources.font(size: 14)))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct PlazaDexCell: View {
    let species: TeamDexSpecies

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlazaCardIcon(speciesID: species.speciesID)
            if species.hasShiny { Text("★").font(.system(size: 10)).foregroundStyle(Color(hex: 0xFFE060)) }
        }
        .frame(width: 44, height: 36)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .help(species.name)
    }
}

/// 박스 아이콘 한 칸. 받는 동안과 실패했을 때는 빈 자리표시.
@MainActor
private struct PlazaCardIcon: View {
    let speciesID: Int?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.25)).padding(4)
            }
        }
        .frame(width: 40, height: 30)
        .task(id: speciesID) {
            image = nil
            guard let id = speciesID else { image = await SpriteLoader.eggImage(); return }
            let loaded = await PlazaIconLoader.icon(speciesID: id)
            if !Task.isCancelled { image = loaded }
        }
    }
}
