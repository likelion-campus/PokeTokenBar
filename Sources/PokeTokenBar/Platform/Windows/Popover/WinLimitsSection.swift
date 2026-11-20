#if os(Windows)
import Foundation
import WinSDK

/// The Home page's official-limits section (stage 7 Task 5, P15–P28): the blocks `HomeModel.limits` lists, top to bottom, as
/// rows of one plain section. A limit row is two page rows: a line (name on the left; detail, reset countdown or idle hint,
/// and the percent in its colour on the right) and the bar, a drawn part (`LimitBarPart`) with the tooltip and the
/// accessible text "<name> <percent>". Reset countdowns and "stale" badges are bound to the page's clock. Windows differences,
/// all listed in the report: a capsule strip wraps to several lines when it does not fit, the Claude help popover is a note
/// opened under the caption.
extension WinHomePage {
    /// The (?) next to Claude's caption: shows or hides the sign-in file's note under it.
    func toggleCredentialHelp() {
        credentialHelpOpen.toggle()
        if let m = last, let s = sections { renderLimits(m.limits, s.limits) }
    }

    func renderLimits(_ blocks: [LimitsBlock]?, _ section: WinSectionCard) {
        rebuild("limits", section) {
            guard let blocks, !blocks.isEmpty else { section.isVisible = false; return }
            section.isVisible = true
            for block in blocks { addLimitsBlock(block, to: section) }
        }
    }

    private func addLimitsBlock(_ block: LimitsBlock, to section: WinSectionCard) {
        switch block {
        case .caption(let title, let help):
            // --- stage 7 Task 14: the (?) and its note come from the model (P15h; Windows: Claude's sign-in file) (begin) ---
            guard let help else {
                section.addStyledRow(label: text(title, .caption, role: .secondary), style: .trailing)
                return
            }
            section.addStyledRow(label: text(title, .caption, role: .secondary), style: .trailing) { pane, ctx in
                guard let c = WinControls.glyphButton(symbol: "questionmark.circle", label: help.tooltip, size: 14, in: pane, ctx: ctx)
                else { return nil }
                c.tooltip = help.tooltip
                c.onClick = { [weak self] in self?.toggleCredentialHelp() }
                return c
            }
            if credentialHelpOpen {
                section.addStyledRow(label: text(help.title, .caption, weight: 600, role: .secondary), style: .trailing)
                section.addStyledRow(label: text(help.body, .caption, role: .secondary), style: .trailing)
                // "Register session key", under the note on the right (the Mac's HStack { Spacer(); Button }): Settings with
                // Advanced open on the key field.
                section.addStyledRow(label: nil, style: .trailing) { pane, ctx in self.button(help.button, in: pane, ctx: ctx) }
            }
            // --- stage 7 Task 14 (end) ---
        case .notice(let n):
            // The Mac's orange card: `.banner` = a semibold caption title with the (bordered) button at its right, 12 % on an 8 pt
            // corner; `.card` = a medium title, the (prominent) button under the hint, 10 % on a 6 pt corner.
            let isBanner = n.style == .banner
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                WinNoticeCard(parent: pane, ctx: ctx, tint: .orange, alpha: isBanner ? 0.12 : 0.10, radius: isBanner ? 8 : 6, spacing: 4,
                              symbol: n.symbol) { child, ctx, tint in
                    var title = WinNoticeCard.Line()
                    title.hasGlyph = true
                    title.flexible = WinControls.label(n.title, style: .caption, weight: isBanner ? 600 : 500, in: child, ctx: ctx)
                    var hint = WinNoticeCard.Line()
                    hint.flexible = WinControls.label(n.hint, style: .caption2, role: .secondary, in: child, ctx: ctx)
                    var lines = [title, hint]
                    if let b = n.button {
                        if isBanner {
                            // Created before the hint in reading order would be wrong: the title's button follows the title.
                            if let c = self.button(b, in: child, ctx: ctx) { lines[0].trailing = [c] }
                        } else if let c = self.pill(b, style: .prominent, in: child, ctx: ctx) {
                            var action = WinNoticeCard.Line()
                            action.leading = [c]
                            action.top = 2
                            lines.append(action)
                        }
                    }
                    for line in lines { if let f = line.flexible { f.background = tint } }
                    return lines
                }?.control
            }
        case .refreshRow(let r):
            var statusLabel: WinControl?
            let status: String
            switch r.status {
            case .tapToLoad(let s): status = s
            case .stale(let rel): status = relativeString(rel)
            }
            section.addStyledRow(label: { pane, ctx in
                statusLabel = WinControls.label(status, style: .callout, role: .secondary, in: pane, ctx: ctx)
                return statusLabel
            }, style: .trailing) { pane, ctx in self.button(r.button, in: pane, ctx: ctx) }
            if case .stale(let rel) = r.status, let statusLabel { bind("limits", statusLabel, rel) }
            if let error = r.error {
                section.addStyledRow(label: text(error, .caption, color: .systemRed), style: .trailing)
            }
        case .accountTabs(let tabs, let selected):
            addTabs(tabs, selected: selected, to: section) { .selectClaudeAccount($0) }
        case .plan(let s):
            section.addStyledRow(label: text(s, .caption, role: .tertiary), style: .trailing)
        case .accountLabel(let s):
            section.addStyledRow(label: text(s, .caption, role: .secondary), style: .trailing)
        case .accountUsage(let today, let month):
            let line = [today, month].map { ([$0.name, $0.tokens] + [$0.cost].compactMap { $0 }).joined(separator: "\u{00A0}") }.joined(separator: "    ")  // a name, its tokens and cost stay together
            section.addStyledRow(label: text(line, .caption, role: .secondary), style: .trailing)
        case .codexMeta(let m):
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                var staleLabel: WinControl?
                let line = WinComposite(parent: pane, ctx: ctx) { child in
                    var parts: [WinControl] = []
                    if let plan = m.plan, let c = WinControls.label(plan, style: .caption, role: .tertiary, wraps: false, in: child, ctx: ctx) { parts.append(c) }
                    if let reached = m.limitReached, let c = WinControls.label(reached, style: .caption, wraps: false, in: child, ctx: ctx) {
                        self.paint(c, .systemRed)
                        parts.append(c)
                    }
                    if let stale = m.stale, let c = WinControls.label(self.relativeString(stale), style: .caption, role: .tertiary, wraps: false, in: child, ctx: ctx) {
                        staleLabel = c
                        parts.append(c)
                    }
                    return (parts, [])
                }
                if let line, let staleLabel, let stale = m.stale { self.bind("limits", staleLabel, stale, in: line) }
                return line?.control
            }
        case .bucketLabel(let s):
            section.addStyledRow(label: text(s, .caption, weight: 600, role: .secondary), style: .trailing)
        case .groupTitle(let s, let dimmed):
            section.addStyledRow(label: text(s, .caption, weight: 600, role: dimmed ? .tertiary : .secondary), style: .trailing)
        case .row(let r, let dimmed):
            addLimitRow(r, dimmed: dimmed, to: section)
        case .forecast(let f):
            let mark = f.warning ? "⚠ " : "✓ "
            section.addStyledRow(label: text(mark + f.text, .caption, role: .tertiary, color: f.warning && !f.dimmed ? .systemOrange : nil),
                                 style: .trailing)
        case .currentBlock(let b):
            let rel = RelativeText(prefix: "\(b.label)  \(b.tokens)    \(b.reset.prefix)", date: b.reset.date, suffix: b.reset.suffix)
            var label: WinControl?
            section.addStyledRow(label: { pane, ctx in
                label = WinControls.label(self.relativeString(rel), style: .caption, role: b.dimmed ? .tertiary : .secondary, in: pane, ctx: ctx)
                return label
            }, style: .trailing)
            if let label { bind("limits", label, rel) }
        case .stale(let rel):
            var label: WinControl?
            section.addStyledRow(label: { pane, ctx in
                label = WinControls.label(self.relativeString(rel), style: .caption, role: .tertiary, in: pane, ctx: ctx)
                return label
            }, style: .trailing)
            if let label { bind("limits", label, rel) }
        case .message(let s):
            section.addStyledRow(label: text(s, .caption, role: .secondary), style: .trailing)
        case .remainingSpend(let s, let dimmed):
            section.addStyledRow(label: text(s, .caption, role: dimmed ? .tertiary : .secondary), style: .trailing)
        case .products(let s, let dimmed):
            section.addStyledRow(label: text(s, .caption, role: dimmed ? .tertiary : .secondary), style: .trailing)
        case .unattributed(let s):
            section.addStyledRow(label: text(s, .caption, role: .tertiary), style: .trailing)
        }
    }

    /// A quota row (`PopoverView.quotaRow`): the line, then the bar.
    private func addLimitRow(_ r: LimitRowModel, dimmed: Bool, to section: WinSectionCard) {
        section.addStyledRow(label: nil, style: .full) { pane, ctx in
            var resetLabel: WinControl?
            let line = WinComposite(parent: pane, ctx: ctx) { child in
                var parts: [WinControl] = []
                if let name = WinControls.label(r.name, style: .callout, role: dimmed ? .secondary : .primary, wraps: false, in: child, ctx: ctx) {
                    parts.append(name)
                }
                var trailing: [WinControl] = []
                if let detail = r.detail, let c = WinControls.label(detail, style: .caption, role: .secondary, wraps: false, in: child, ctx: ctx) {
                    trailing.append(c)
                }
                if let reset = r.resetText {
                    resetLabel = WinControls.label(self.relativeString(reset), style: .caption, role: .tertiary, wraps: false, in: child, ctx: ctx)
                    if let resetLabel { trailing.append(resetLabel) }
                } else if let hint = r.idleHint, let c = WinControls.label(hint, style: .caption, role: .tertiary, wraps: false, in: child, ctx: ctx) {
                    trailing.append(c)
                }
                if let percent = WinControls.label(r.percentText, style: .callout, wraps: false, in: child, ctx: ctx) {
                    if dimmed { percent.role = .secondary } else { self.paint(percent, r.percentColor) }
                    trailing.append(percent)
                }
                return (parts, trailing)
            }
            if let line, let resetLabel, let reset = r.resetText { self.bind("limits", resetLabel, reset, in: line) }
            return line?.control
        }
        let widthDIP = CGFloat(innerWidth) / ctx.scale
        section.addStyledRow(label: nil, style: .full) { pane, ctx in
            guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            let part = LimitBarPart(LimitBarPart.Model(name: r.name, percentText: r.percentText, fillPercent: r.fillPercent, tint: r.tint,
                                                       paceMarker: r.paceMarker, help: r.help, dimmed: dimmed))
            view.host(part, width: widthDIP)
            self.bars.append(view)
            return view.control
        }
    }
}
#endif
