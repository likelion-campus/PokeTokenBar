import AppKit

/// 광장 아래쪽의 한 줄 입력창. 닫혀 있으면 보이지 않는다. 글자는 AppKit 입력창이 받으므로 한글 조합이 그대로 되고,
/// 열린 동안 장면은 키를 받지 않아 포켓몬이 움직이거나 이모트가 나가지 않는다.
@MainActor final class PlazaChatInput: NSObject, NSTextFieldDelegate {
    let view = NSView()
    let field = PlazaChatTextField()
    /// 오른쪽 끝의 😀. 입력칸 위에 이모지 판을 펼치고 접는다.
    let emojiButton = NSButton(title: "😀", target: nil, action: nil)
    /// 자주 쓰는 이모지. macOS 이모지 창은 이 앱에서 뜨지 않는 Mac이 있어(⌃⌘Space와 🌐 키도) 앱 안에 판을 둔다.
    static let emojis = [
        "😀", "😂", "🤣", "😊", "😍", "🥰", "😎", "🤔", "😅", "😭",
        "😢", "😡", "🥺", "😴", "🤯", "🥳", "👍", "👎", "👏", "🙏",
        "🙌", "💪", "👀", "🔥", "✨", "🎉", "❤️", "💯", "✅", "❌",
        "☕", "🍜", "🍕", "🍺", "🎂", "☀️", "🌧️", "💻", "🐛", "🚀",
    ]
    static let emojiColumns = 10
    static let emojiCell: CGFloat = 32
    /// 입력칸 위의 이모지 판. 펼쳤을 때만 입력창 안에 들어가고, 입력창이 그만큼 위로 커진다.
    let emojiPanel = NSGridView()
    private(set) var emojiPanelButtons: [NSButton] = []
    var isEmojiPanelOpen: Bool { emojiPanel.superview != nil }
    private var fieldTop: NSLayoutConstraint!
    private var panelConstraints: [NSLayoutConstraint] = []
    /// 입력한 글을 넘긴다. false면 입력창을 닫지 않고 글을 남긴다.
    var onSubmit: ((String) -> Bool)?
    /// 어떤 이유로든 닫히면 부른다.
    var onClose: (() -> Void)?
    /// 지금 키가 눌린 채 반복 중인지. 테스트에서 바꿔 끼운다.
    var isKeyRepeating: () -> Bool = { NSApp.currentEvent?.isARepeat == true }
    private(set) var isOpen = false
    /// 확성기로 보낸다. Tab으로 켜고 끄며, 입력창을 열 때마다 꺼진다.
    private(set) var isLoud = false {
        didSet { refreshLoud() }
    }

    override init() {
        super.init()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: 0x1D / 255, green: 0x4F / 255, blue: 0x5C / 255, alpha: 0.95)
        view.layer?.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.isHidden = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = PlazaResources.font(.body)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        refreshLoud()
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        // 단추가 첫 응답자를 가져가면 입력이 끝나 입력창이 닫히므로 받지 않는다.
        emojiButton.refusesFirstResponder = true
        emojiButton.isBordered = false
        emojiButton.font = .systemFont(ofSize: 16)
        emojiButton.toolTip = L(.ko).plazaChatEmoji
        emojiButton.target = self
        emojiButton.action = #selector(emojiPressed)
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emojiButton)
        buildEmojiPanel()
        // 입력창 기본 높이(18)는 갈무리 글꼴의 줄 높이(21)보다 낮아 ㅎ 꼭지 같은 글자 윗부분이 잘린다.
        // 글자는 줄의 위쪽에 그려지므로 입력창을 4pt 내려 글자가 막대 가운데에 오게 한다.
        fieldTop = field.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        panelConstraints = [
            emojiPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            emojiPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            field.topAnchor.constraint(equalTo: emojiPanel.bottomAnchor, constant: 8),
        ]
        NSLayoutConstraint.activate([
            field.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            fieldTop,
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor, constant: -4),
            emojiButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            emojiButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            emojiButton.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// 글꼴의 한 줄 높이. 입력창은 이보다 낮으면 글자 윗부분을 잘라 그린다.
    static let fieldHeight = NSLayoutManager().defaultLineHeight(for: PlazaResources.font(.body)).rounded(.up)

    private func buildEmojiPanel() {
        emojiPanelButtons = Self.emojis.map { emoji in
            let b = NSButton(title: emoji, target: self, action: #selector(emojiPicked(_:)))
            // 이모지를 눌러도 입력칸이 계속 글을 받아야 한다(첫 응답자를 가져가면 입력창이 닫힌다).
            b.refusesFirstResponder = true
            b.isBordered = false
            b.font = .systemFont(ofSize: 20)
            return b
        }
        let rows = stride(from: 0, to: emojiPanelButtons.count, by: Self.emojiColumns).map {
            Array(emojiPanelButtons[$0..<min($0 + Self.emojiColumns, emojiPanelButtons.count)])
        }
        for row in rows { emojiPanel.addRow(with: row) }
        emojiPanel.rowSpacing = 0
        emojiPanel.columnSpacing = 0
        for i in 0..<emojiPanel.numberOfColumns { emojiPanel.column(at: i).width = Self.emojiCell }
        for i in 0..<emojiPanel.numberOfRows { emojiPanel.row(at: i).height = Self.emojiCell }
        emojiPanel.xPlacement = .center
        emojiPanel.yPlacement = .center
        emojiPanel.translatesAutoresizingMaskIntoConstraints = false
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        isLoud = false
        field.stringValue = ""
        setEmojiPanel(open: false)
        view.isHidden = false
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        setEmojiPanel(open: false)
        field.stringValue = ""
        view.isHidden = true
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // false를 돌려주면 입력이 끝나 입력창이 닫히고 글이 사라진다. 조합 중이면 글자만 확정한다.
            if textView.hasMarkedText() {
                textView.unmarkText()
                return true
            }
            // 입력창을 연 Enter를 누르고 있으면 반복 입력이 빈 입력창을 바로 닫는다.
            if isKeyRepeating() { return true }
            if onSubmit?(textView.string) != false { close() }
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // 입력창을 벗어나면 닫히므로 Tab은 포커스를 옮기지 않고 확성기를 켜고 끈다.
            isLoud.toggle()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func refreshLoud() {
        let l = L(.ko)
        field.placeholderAttributedString = NSAttributedString(string: isLoud ? l.plazaLoudPlaceholder : l.plazaChatPlaceholder, attributes: [
            .font: PlazaResources.font(.body), .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
        view.layer?.borderColor = isLoud ? CGColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0x24 / 255, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
    }

    @objc private func emojiPressed() {
        setEmojiPanel(open: !isEmojiPanelOpen)
    }

    /// 판은 입력칸 위에 들어가 입력창을 위로 키운다. 닫으면 빠지고 입력창이 원래 높이로 돌아온다.
    private func setEmojiPanel(open: Bool) {
        guard open != isEmojiPanelOpen else { return }
        if open {
            view.addSubview(emojiPanel)
            fieldTop.isActive = false
            NSLayoutConstraint.activate(panelConstraints)
        } else {
            NSLayoutConstraint.deactivate(panelConstraints)
            emojiPanel.removeFromSuperview()
            fieldTop.isActive = true
        }
    }

    @objc private func emojiPicked(_ sender: NSButton) {
        insert(sender.title)
    }

    /// 커서 자리에 넣는다. 조합 중인 한글은 Enter처럼 먼저 확정한다. 길이 제한은 글이 바뀔 때(`controlTextDidChange`) 지킨다.
    func insert(_ text: String) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// 조합 중인 글자를 건드리면 한글이 깨지므로 조합이 끝난 뒤에 자른다.
    func controlTextDidChange(_ notification: Notification) {
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        if field.stringValue.count > TeamChat.maxCharacters {
            field.stringValue = String(field.stringValue.prefix(TeamChat.maxCharacters))
        }
    }

    /// 지도를 눌러 입력창을 벗어나면 닫는다. 닫지 않으면 Esc가 입력창 대신 광장을 닫는다.
    func controlTextDidEndEditing(_ notification: Notification) {
        close()
    }
}

final class PlazaChatTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = currentEditor(),
              let action = Self.commandAction(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        let target: Any? = action == #selector(NSWindow.performClose(_:)) ? window : editor
        return NSApp.sendAction(action, to: target, from: self)
    }

    /// 앱에 메인 메뉴가 없어 입력창이 단축키를 직접 처리한다. 한글 입력기에서는 문자가 달라지므로 keyCode로 판정한다.
    static func commandAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Selector? {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else { return nil }
        switch keyCode {
        case 0: return #selector(NSText.selectAll(_:))
        case 7: return #selector(NSText.cut(_:))
        case 8: return #selector(NSText.copy(_:))
        case 9: return #selector(NSText.paste(_:))
        case 13: return #selector(NSWindow.performClose(_:))
        default: return nil
        }
    }
}
