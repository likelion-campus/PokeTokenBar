import SwiftUI
import AppKit
@testable import PokeTokenBar

/// The SwiftUI shortcut guide, background toggle, name-colour picker and photo frame as they were before Track A Task 15
/// drew them as shared panels: the bodies are `PlazaShortcutGuideView.swift`, `PlazaChatLogView.swift` (toggle, picker) and
/// `PlazaOverlayView.swift` (photo frame) verbatim, with the guide's entries read from the shared `PlazaShortcutGuide`.
/// `PlazaHUDControlRenderTests+Mac` measures their layout and renders the PR's "before" images from them. Deleted in
/// Task 19 with the rest of `Legacy/`.
@MainActor
struct LegacyPlazaShortcutGuide: View {
    let model: PlazaShortcutGuideModel
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Text(L(.ko).plazaShortcutsTitle)
                    Image(systemName: model.isFolded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            if !model.isFolded {
                ForEach(PlazaShortcutGuide.entries(season: model.season), id: \.key) { entry in
                    HStack(spacing: 6) {
                        Text(entry.key)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15)))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1))
                        Text(entry.label)
                    }
                    .fixedSize()   // 키 이름이 "Spa…"처럼 잘리지 않게 한다.
                }
            }
        }
        .font(Font(PlazaResources.font(.small)))
        .foregroundStyle(Color(hex: 0xF8F8F0))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
    }
}

@MainActor
struct LegacyPlazaBackgroundToggle: View {
    let model: PlazaBackgroundModel
    let toggle: () -> Void

    var body: some View {
        let l = L(.ko)
        Button(action: toggle) {
            Label(model.isHidden ? l.plazaBackgroundShow : l.plazaBackgroundHide,
                  systemImage: model.isHidden ? "eye" : "eye.slash")
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

@MainActor
struct LegacyPlazaNameColorPicker: View {
    static let columns = 6
    static let swatch: CGFloat = 20
    let model: PlazaNameColorModel
    let toggle: () -> Void
    let choose: (UInt32) -> Void

    var body: some View {
        let l = L(.ko)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: model.current)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(hex: 0x14161F), lineWidth: 1.5))
                    Text(l.plazaNameColor)
                }
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .focusable(false)
            if model.isOpen {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.swatch + 4), spacing: 4), count: Self.columns), spacing: 4) {
                    ForEach(Array(PlazaNameColor.hexes.enumerated()), id: \.offset) { i, hex in
                        Button { choose(hex) } label: {
                            Circle().fill(Color(hex: hex)).frame(width: Self.swatch, height: Self.swatch)
                                .overlay(Circle().stroke(Color(hex: 0x14161F), lineWidth: 1.5))
                                .padding(2)
                                .overlay(Circle().stroke(Color.white, lineWidth: hex == model.current ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel(l.plazaNameColorChoice(i + 1))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            }
        }
    }
}

/// The overlay's photo frame (`PlazaOverlayView.photoFrame`) in the overlay's own `ZStack`, content none.
@MainActor
struct LegacyPlazaPhotoFrame: View {
    let model: PlazaOverlayModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if model.isPhotoMode { photoFrame }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoFrame: some View {
        GeometryReader { geo in
            if let frame = PlazaPhotoFrame.viewRect(in: geo.size) {
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Path { p in
                    // 선이 틀 안쪽에 놓이도록 선 두께의 절반만큼 들여 그린다.
                    let arm = PlazaPhotoFrame.bracketArm, h = PlazaPhotoFrame.bracketWidth / 2
                    let r = frame.insetBy(dx: h, dy: h)
                    for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                             (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                        p.addLine(to: corner)
                        p.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: PlazaPhotoFrame.bracketWidth, lineCap: .butt, lineJoin: .miter))
                Text(L(.ko).plazaPhotoGuide)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: frame.width, height: PlazaPhotoFrame.bottomInset, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height - PlazaPhotoFrame.bottomInset / 2)
            }
            }
        }
        .allowsHitTesting(false)
    }
}
