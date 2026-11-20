#if os(Windows)
import Foundation
import WinSDK

/// The pieces of the Shop's and Bag's cards (stage 7 Task 19): labels in the Mac's text styles and colours, the three button
/// looks of the cards (`.bordered`, `.borderedProminent`, `.borderless`, all `.controlSize(.small)`), and the item icon.
@MainActor enum WinCardKit {
    /// A one-line (or wrapping) label; `color` is a model colour (the owned mark's green), `role` the page's text roles.
    static func label(_ text: String, _ style: PopoverTextStyle, weight: Int? = nil, role: WinUIColors.Role = .primary,
                      color: PopoverColorRole? = nil, wraps: Bool = false, maxLines: Int? = nil, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let c = WinControls.label(text, style: style, weight: weight, role: role, wraps: wraps, maxLines: maxLines, in: pane, ctx: ctx) else { return nil }
        if let color { c.textColor = colorRef(color, ctx: ctx) }
        return c
    }

    /// A colour role's value in the page's appearance (light, dark or high contrast), as a `COLORREF`.
    static func colorRef(_ role: PopoverColorRole, ctx: WinUIContext) -> COLORREF { ctx.colors.roleColor(role) }

    /// The wallet's total: the label made at `.largeBold`, then set at 24 DIP semibold in Segoe UI Variable Display (the Windows
    /// ramp's display2; the Mac's is 24 pt bold).
    static func bigNumber(_ text: String, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let c = WinControls.label(text, style: .largeBold, wraps: false, in: pane, ctx: ctx), let font = ctx.fonts.sized(24, weight: 600) else {
            return nil
        }
        WinKit.setFont(c.hwnd, font)
        let s = ctx.measure(text, font: font)
        c.preferredSize = CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy))
        return c
    }

    /// `.buttonStyle(.bordered).controlSize(.small)`: the native push button, repainted small (24 DIP).
    static func bordered(_ title: String, in pane: HWND, ctx: WinUIContext, _ action: @escaping () -> Void) -> WinControl? {
        let c = WinControls.button(title, small: true, in: pane, ctx: ctx)
        c?.onClick = action
        return c
    }

    /// `.borderedProminent` and `.borderless` (small): the kit's pills, as the update offer's buttons.
    static func pill(_ title: String, _ style: WinPill.Style, in pane: HWND, ctx: WinUIContext, _ action: @escaping () -> Void) -> WinControl? {
        let c = WinControls.pillButton(WinPill(style: style, title: title, textStyle: .callout), in: pane, ctx: ctx)
        c?.onClick = action
        return c
    }

    /// A drawn view is held weakly by its own control and window handlers, so something must own it: the control does, through a
    /// closure that runs when the control is destroyed (and is dropped then). Without an owner the view is freed at once and its
    /// picture (a bitmap and a device context) is never released.
    private static func own(_ view: WinDrawnView) {
        guard let control = view.control else { return }
        let freeing = control.onDestroy
        control.onDestroy = { freeing?(); _ = view }
    }

    /// The item icon (`ItemIconView`, 30 pt): the emoji at once, the sprite when the store has it (a cache hit at once, else loaded
    /// and swapped in while the page is current).
    static func itemIcon(_ kind: ItemKind, host: WinTabHost, source: any PopoverItemSource, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
        own(view)
        let name = kind.spriteName
        let part = ItemIconPart(kind: kind, image: name.flatMap { PopoverItemImages.cached(name: $0, directory: source.directory) })
        view.host(part, width: part.side)
        if part.image == nil, let name {
            Task { @MainActor [weak host] in
                let image = await PopoverItemImages.load(name: name, source: source)
                host?.whenCurrent { part.update(image) }
            }
        }
        return view.control
    }

    /// A sprite slot in a square box (the egg of an egg card, the Bag's Snorlax), animated by `sprites`.
    static func spriteBox(_ part: SpriteBoxPart, sprites: WinSpriteAnimator?, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
        own(view)
        view.sprites = sprites
        view.host(part, width: part.box)
        return view.control
    }

    /// The egg card's tier badge, drawn by the companion header's badge code.
    static func badge(_ badge: CompanionHeaderModel.Badge, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
        own(view)
        view.host(BadgePart(badge), width: 200)
        return view.control
    }

    /// The control that has the keyboard, by the name it was registered under (so a card made again keeps it).
    static func focusedName(_ controls: [String: WinControl]) -> String? {
        guard let focus = GetFocus() else { return nil }
        for (name, c) in controls where c.parts.contains(where: { $0 == focus || IsChild($0, focus) }) { return name }
        return nil
    }

    static func restoreFocus(_ name: String?, _ controls: [String: WinControl]) {
        guard let name, let c = controls[name], c.isEnabled else { return }
        _ = SetFocus(c.kind == .radioGroup ? c.parts[max(0, min(c.parts.count - 1, c.selection))] : c.hwnd)
    }
}
#endif
