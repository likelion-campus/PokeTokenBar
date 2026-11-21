// The SwiftUI overlay (board and member card) as the Mac window showed it before Track A Task 17w switched the window to the shared
// `PlazaBoardPanel` and `PlazaCardPanel`: `PlazaOverlayView.swift`, `PlazaBoardView.swift` and `PlazaCardView.swift` verbatim (types
// renamed). Kept so the panels' render tests can draw their "before" from the real views and the click tests can compare hit regions.
// Deleted in Task 19 with the rest of `Legacy/`.
import SwiftUI
import AppKit
@testable import PokeTokenBar


/// 광장 가운데에 뜨는 판. 내용이 없으면 아무것도 그리지 않는다.
@MainActor
struct LegacyPlazaOverlayView: View {
    let model: PlazaOverlayModel
    var feed: TeamFeedStore?
    var myMemberID = ""
    var onReact: (_ eventID: String, _ kind: TeamReactionKind) -> Void = { _, _ in }

    var body: some View {
        ZStack(alignment: .top) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .none:
            Color.clear
        case .board:
            panel(CGSize(width: 340, height: 380)) {
                if let feed { LegacyPlazaBoardView(feed: feed, myMemberID: myMemberID, onReact: onReact) }
            }
        case .card(let state):
            panel(PlazaCardMetrics.panelSize) { LegacyPlazaCardView(state: state) }
        case .memberMenu, .campfireMenu, .gameMenu:
            Color.clear   // the menus and their tap-outside area are the shared `PlazaMenuPanel`
        }
    }

    private func panel<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(PlazaCardMetrics.panelInset)
            .frame(width: size.width, height: size.height)
            .background(PlazaRosterBackground())
    }
}

/// 열려 있을 때만 마우스(스크롤, 버튼)를 받는다. 키는 받지 않아 SKView가 첫 응답자를 유지한다.
final class LegacyPlazaOverlayHostingView: NSHostingView<LegacyPlazaOverlayView> {
    private let model: PlazaOverlayModel

    init(rootView: LegacyPlazaOverlayView, model: PlazaOverlayModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init(rootView: LegacyPlazaOverlayView) { fatalError("use init(rootView:model:)") }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        MainActor.assumeIsolated {
            switch model.content {
            case .none, .memberMenu, .campfireMenu, .gameMenu: nil   // menus are panels (their own host takes the clicks)
            case .board, .card: super.hitTest(point)
            }
        }
    }
    override var acceptsFirstResponder: Bool { false }
}


/// 소식판: 새 소식이 위. 줄마다 문구, 날짜, 달린 반응, 반응 버튼 셋.
@MainActor
struct LegacyPlazaBoardView: View {
    let feed: TeamFeedStore
    let myMemberID: String
    let onReact: (_ eventID: String, _ kind: TeamReactionKind) -> Void

    var body: some View {
        let l = L(.ko)
        let rows = PlazaBoardRow.rows(feed: feed, myMemberID: myMemberID)
        VStack(spacing: 8) {
            Text(l.plazaBoardTitle)
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
            if rows.isEmpty {
                Text(l.plazaBoardEmpty)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            LegacyPlazaBoardRowView(row: row) { onReact(row.id, $0) }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct LegacyPlazaBoardRowView: View {
    let row: PlazaBoardRow
    let onReact: (TeamReactionKind) -> Void

    var body: some View {
        let l = L(.ko)
        let lineColor = row.isShiny ? Color(hex: 0xFFE060) : Color.white
        VStack(alignment: .leading, spacing: 4) {
            Text((row.isShiny ? "★ " : "") + row.text)
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(lineColor)
                // Only regular weights ship, so `.fontWeight(.bold)` would do nothing: a same-colour shadow
                // one font dot (1pt at the body size) to the side thickens the strokes instead.
                .shadow(color: row.isBig ? lineColor : .clear, radius: 0, x: 1, y: 0)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.date)
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(.white.opacity(0.65))
            if !row.reactions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(row.reactions, id: \.kind) { r in
                        Text(l.teamReactionLabel(r.kind) + " " + r.nicknames.joined(separator: ", "))
                            .font(Font(PlazaResources.font(.small)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(PlazaBoardRow.buttonKinds, id: \.self) { kind in
                    Button { onReact(kind) } label: {
                        Text(l.teamReactionLabel(kind))
                            .font(Font(PlazaResources.font(.small)))
                            .foregroundStyle(Color(hex: 0x2D4048))
                            .frame(minWidth: 30)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0xF8F8F0).opacity(row.mine.contains(kind) ? 0.4 : 1),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(row.mine.contains(kind))
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}


/// 팀원 카드: 누구의 카드인지, 광장 캐릭터(크게, 이로치·희귀도 표시), 도감 격자(이로치 ★, 전설 표시).
/// 읽기 전용이고 수치(보유 수, 진행률, 희귀도 합계)는 두지 않는다.
@MainActor
struct LegacyPlazaCardView: View {
    let state: PlazaCardState

    var body: some View {
        let l = L(.ko)
        VStack(spacing: PlazaCardMetrics.stackSpacing) {
            header
            LegacyPlazaCardActivity(activity: state.todayActivity())
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
                            LegacyPlazaDexCell(species: species)
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
            LegacyPlazaCardSprite(mon: member.character)
            VStack(alignment: .leading, spacing: 6) {
                Text(l.plazaCardTitle(nickname: member.nickname))
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(Color(plaza: PlazaNameColor.color(forMemberID: member.memberID, chosen: member.nameColor)))
                    .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let name = state.characterName {
                    Text(name)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                let badges = state.characterBadges
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in LegacyPlazaCardPill(badge: badge) }
                    }
                }
                if let other = state.differingCurrent { LegacyPlazaCardIcon(speciesID: other.speciesID, size: CGSize(width: 40, height: 30)) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: PlazaCardMetrics.spriteSide)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Font(PlazaResources.font(.body)))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 오늘 광장에서 한 일. 일곱 줄을 두 열(왼쪽 4, 오른쪽 3)로 놓아 카드의 도감 칸을 덜 가린다. 기록이 없어도 높이는 같다.
@MainActor
private struct LegacyPlazaCardActivity: View {
    let activity: PlazaActivity?

    var body: some View {
        let l = L(.ko)
        let rows = PlazaActivity.rows(activity)
        VStack(alignment: .leading, spacing: 0) {
            Text(l.plazaCardActivityTitle)
                .frame(height: PlazaCardMetrics.activityTitleHeight, alignment: .leading)
            if rows.isEmpty {
                Text(l.plazaActivityNone).frame(height: PlazaCardMetrics.activityRowHeight)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    column(Array(rows.prefix(4)))
                    column(Array(rows.dropFirst(4)))
                }
            }
            Spacer(minLength: 0)
        }
        .font(Font(PlazaResources.font(.small)))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
        .padding(.horizontal, 10).padding(.vertical, PlazaCardMetrics.activityPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: PlazaCardMetrics.activityHeight, alignment: .top)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func column(_ rows: [PlazaActivity.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    Text(row.label).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(row.value).lineLimit(1)
                }
                .frame(height: PlazaCardMetrics.activityRowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 이로치는 노란 바탕, 희귀도는 앱의 희귀도 색.
@MainActor
private struct LegacyPlazaCardPill: View {
    let badge: PlazaCardBadge

    var body: some View {
        let l = L(.ko)
        let (text, fill, ink): (String, Color, Color) = switch badge {
        case .shiny: (l.plazaCardShiny, Color(hex: 0xFFE060), Color(hex: 0x2D4048))
        case .rarity(let r): (l.rarityLabel(r), rarityColor(r), .white)
        }
        Text(text)
            .font(Font(PlazaResources.font(.small)))
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

@MainActor
private struct LegacyPlazaDexCell: View {
    let species: TeamDexSpecies

    var body: some View {
        let legendary = species.rarity == .legendary
        VStack(spacing: 1) {
            LegacyPlazaCardIcon(speciesID: species.speciesID, size: PlazaCardMetrics.iconSize)
            // 긴 이름은 끝을 줄인다. 전체 이름은 마우스를 올리면 보인다.
            Text(species.name)
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PlazaCardMetrics.cellSize.width - 4)
        }
        .frame(width: PlazaCardMetrics.cellSize.width, height: PlazaCardMetrics.cellSize.height)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if legendary { RoundedRectangle(cornerRadius: 6).stroke(rarityColor(.legendary), lineWidth: 1.5) }
        }
        .overlay(alignment: .topLeading) {
            if legendary { LegacyPlazaCardPill(badge: .rarity(.legendary)).padding(2) }
        }
        .overlay(alignment: .topTrailing) {
            if species.hasShiny {
                Text("★").font(.system(size: 12)).foregroundStyle(Color(hex: 0xFFE060)).padding(.top, 2).padding(.trailing, 4)
            }
        }
        .help(species.name)
    }
}

/// 광장 캐릭터를 크게. 이로치면 이로치 그림이다. 받는 동안과 실패했을 때는 빈 자리표시.
@MainActor
private struct LegacyPlazaCardSprite: View {
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
private struct LegacyPlazaCardIcon: View {
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

