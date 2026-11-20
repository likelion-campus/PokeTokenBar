import SwiftUI
import AppKit
@testable import PokeTokenBar

/// The SwiftUI pills (countdown, banner, hint) and clock as they were before Track A Task 14 drew them as shared panels:
/// the pill stack is `PlazaOverlayView`'s top `VStack` verbatim (with the overlay's `ZStack` around it, content `.none`,
/// no menu), the clock is `PlazaClockView.swift`'s `PlazaClock` verbatim except that a test can pin its date (as
/// `PlazaMinimapView.fixedDate` does). `PlazaPanelRenderTests+Mac` measures their layout and renders the PR's "before"
/// images from them. Deleted in Task 19 with the rest of `Legacy/`.
@MainActor
struct LegacyPlazaPills: View {
    let model: PlazaOverlayModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            VStack(spacing: 8) {
                if let countdown = model.countdown {
                    Text(countdown)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color(hex: 0x1D4F55).opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xF2C14E), lineWidth: 2))
                        .allowsHitTesting(false)
                }
                if let banner = model.banner {
                    Text(banner)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: 360)
                        .background(Color(hex: 0x1D4F55).opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x5FB7BD), lineWidth: 2))
                        .allowsHitTesting(false)
                }
                if let hint = model.hint {
                    Text(hint)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(Color(hex: 0xF8F8F0))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, PlazaRosterMetrics.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `PlazaClock` before Task 14. `date` nil follows the clock every minute, as the window did.
@MainActor
struct LegacyPlazaClock: View {
    let model: PlazaMinimapModel
    var date: Date?

    var body: some View {
        if let date {
            text(date)
        } else {
            TimelineView(.everyMinute) { context in text(context.date) }
        }
    }

    private func text(_ date: Date) -> some View {
        Text(PlazaDaylight.clockText(date, core: model.coreTime))
            .font(Font(PlazaResources.font(.small)))
            .foregroundStyle(Color(hex: 0xF8F8F0))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
    }
}
